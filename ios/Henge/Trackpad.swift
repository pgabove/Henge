import SwiftUI
import UIKit

/// A surface that works like a Mac's trackpad — it is one: the engine presents it on
/// the Mac's USB bus as a Magic Trackpad 2, so the Mac's own multitouch engine sees
/// the fingers: two scroll, three swipe between Spaces and to Mission Control, four
/// show the session's hidden controls.
///
/// Clicking depends on the input mode (Settings > Trackpad):
///  - Touchscreen: the surface itself clicks. A quick tap is a left click, a quick
///    two-finger tap is a right click, and touching then holding presses the button
///    down so moving drags. These go out as mouse buttons alongside the pad's fingers.
///  - Volume buttons: the surface only points and gestures; the clicks live on the
///    volume keys (VolumeClicks), so a tap here does nothing.
/// Only fingers count: a real trackpad or mouse goes through HardwareMouse.
///
/// With Settings > Touchscreen on, the Mac also has a USB touchscreen (the kind a touch
/// monitor's panel is), and the surface over the Mac's picture is its glass. What a
/// gesture is then depends on what macOS takes the touchscreen as (henge_vm_ts_mode):
///  - A pointer, which is every macOS so far: a panel is a pointer that is where the
///    finger is. One finger acts where it lands: a tap clicks there, moving drags from
///    there, and staying put is a right click. A second finger makes it a gesture for
///    the Mac's trackpad instead, at that spot: two scroll and pinch what is under
///    them, and a quick two-finger tap is a right click.
///  - Touches, if macOS asks the panel for them: every finger goes to the Mac as it is,
///    and what it does is macOS's to decide.
///  - Nothing yet (macOS has not set the touchscreen up): the surface is the trackpad.
/// Four fingers still show the session's controls.
struct Trackpad: UIViewRepresentable {
    /// Four fingers tapped together: the session shows its hidden controls.
    static let revealTap = Notification.Name("henge.trackpad.revealTap")
    /// The setting: the next Mac to start gets the touchscreen.
    static let directTouchKey = "henge.touchscreen.direct"
    /// And, with it: if macOS asks the touchscreen for touches, it gets them (EngineTuning). Off, it stays a pointer.
    static let nativeTouchKey = "henge.touchscreen.native"

    /// Where the Mac's picture is in this view, when the Mac has the touchscreen and this
    /// surface lies over its picture. nil: the surface is the Mac's trackpad.
    var picture: CGRect? = nil

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) { view.picture = picture }

    final class Surface: UIView, UIPointerInteractionDelegate {
        /// The emulated pad's sensor, in the Magic Trackpad 2's own units.
        private static let sensorW: Int32 = 8134
        private static let sensorH: Int32 = 5206
        private static let holdTime: TimeInterval = 0.4
        private static let tapTime: TimeInterval = 0.3
        private static let tapDistance: CGFloat = 8
        /// On the touchscreen as a pointer: a finger that stays put this long is a right click.
        private static let pressTime: TimeInterval = 0.55
        /// And a tap this soon after another, this near it, lands exactly on it: a double click has to
        /// be two clicks in one place, which two taps of a finger are not.
        private static let againTime: TimeInterval = 0.45
        private static let againDistance: CGFloat = 28

        /// What a finger is: on the trackpad, on the Mac's touchscreen as a touch, the one finger
        /// the touchscreen's pointer follows, or nothing to the Mac (it came down beside the Mac's
        /// picture, or after the gesture was settled).
        private enum Kind { case pad, screen, point, neither }
        private struct Finger { var touch: UITouch; var id: Int32; var kind: Kind }

        /// What the gesture under way is, settled by its first finger: the trackpad's, touches on
        /// the Mac's touchscreen, or the touchscreen as a pointer.
        private enum Gesture { case pad, touches, pointer }
        /// The touchscreen as a pointer, through one gesture: nothing yet; a finger is down and has
        /// done nothing (a tap, a press, a drag or a trackpad gesture may come of it); it is dragging
        /// with the button down; more fingers joined and it is the trackpad's; or it is over.
        private enum Pointing { case idle, aiming, dragging, gesturing, done }

        /// The Mac's picture in this view when the surface is its touchscreen (Trackpad.picture).
        var picture: CGRect?

        private var fingers: [Finger] = []
        private var freeIds = Set<Int32>(1...5) /* a touch screen reports five fingers at most */
        private var started = Date()
        private var travelled: CGFloat = 0
        private var mostFingers = 0
        private var touchesLogged = 0
        private var gesture = Gesture.pad

        /* Touchscreen-mode clicking. */
        private var holding = false
        private var holdTimer: Timer?
        private let buzz = UIImpactFeedbackGenerator(style: .medium)
        private var tapsClick: Bool { VolumeClicks.inputMode == .touchscreen && gesture == .pad }

        /* The touchscreen as a pointer. */
        private var pointing = Pointing.idle
        private var aimStart = CGPoint.zero                 /* where the finger came down, in this view */
        private var aim: (x: Int32, y: Int32) = (0, 0)      /* and on the Mac's screen */
        private var pointAt: (x: Int32, y: Int32) = (0, 0)  /* where the pointer was last sent */
        private var pressTimer: Timer?
        private var lastTapTime = Date.distantPast             /* the last tap: when, where in this view, */
        private var lastTapStart = CGPoint.zero
        private var lastTapAim: (x: Int32, y: Int32) = (0, 0)  /* and where on the Mac's screen */

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            addInteraction(UIPointerInteraction(delegate: self))
        }

        /// Over the Mac there is only the Mac's pointer, if iPadOS hasn't locked its own away.
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

        required init?(coder: NSCoder) { fatalError("made in code") }

        /// Where the finger is on the pad's sensor, in its units.
        private func sensor(_ t: UITouch) -> (Int32, Int32) {
            let p = t.location(in: self)
            // One scale for both axes. The view and the pad's sensor are different
            // shapes, so stretching the view to fill the sensor would make a finger
            // move the pointer further on one axis than the other. Map the view to a
            // centred part of the sensor at a single scale instead.
            let w = max(Double(bounds.width), 1), h = max(Double(bounds.height), 1)
            let scale = min(Double(Self.sensorW) / w, Double(Self.sensorH) / h)
            let x = (Double(p.x) - w / 2) * scale + Double(Self.sensorW) / 2
            let y = (Double(p.y) - h / 2) * scale + Double(Self.sensorH) / 2
            return (Int32(min(max(x, 0), Double(Self.sensorW))),
                    Int32(min(max(y, 0), Double(Self.sensorH))))
        }

        /// Where the finger is on the Mac's screen, 0...32767 each way from its top left; nil when this
        /// surface is a trackpad. `beside` is a finger off the picture (on the bars around it, where
        /// the shapes differ). A little past the edge still counts, so the very edge can be reached.
        private func screenSpot(_ t: UITouch) -> (x: Int32, y: Int32, beside: Bool)? {
            guard let r = picture, r.width > 1, r.height > 1 else { return nil }
            let p = t.location(in: self)
            let fx = Double((p.x - r.minX) / r.width), fy = Double((p.y - r.minY) / r.height)
            let slack = 0.02
            let beside = fx < -slack || fx > 1 + slack || fy < -slack || fy > 1 + slack
            let x = Int32((min(max(fx, 0), 1) * 32767).rounded()), y = Int32((min(max(fy, 0), 1) * 32767).rounded())
            return (x, y, beside)
        }

        /* A touch sample's own clock, in ms. The guest derives finger speed from the
           timestamp deltas, so reports must carry the sample time, not the moment we
           process the event -- otherwise a burst of samples reads as one enormous flick
           and scroll inertia goes wild on release. */
        private static func ms(_ t: TimeInterval) -> UInt32 { UInt32(truncatingIfNeeded: Int(t * 1000)) }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = touches.filter { $0.type != .indirectPointer }
            guard !touches.isEmpty else { return }
            if fingers.isEmpty {
                started = Date()
                travelled = 0
                mostFingers = 0
                /* What this gesture is: the trackpad's, unless this surface is the Mac's touchscreen and
                   macOS has set that up. */
                let touchscreen: Int32 = picture == nil ? 0 : henge_vm_ts_mode()
                switch touchscreen {
                case 2: gesture = .touches
                case 1: gesture = .pointer
                default: gesture = .pad
                }
                pointing = .idle
                if tapsClick || gesture == .pointer { buzz.prepare() }
            }
            for t in touches {
                guard let id = freeIds.min() else { break }
                freeIds.remove(id)
                let ts = Self.ms(t.timestamp)
                if gesture != .pad, let spot = screenSpot(t) {
                    if gesture == .pointer {
                        pointerBegan(t, id: id, x: spot.x, y: spot.y, beside: spot.beside, ts: ts)
                    } else {
                        /* The Mac has asked its touchscreen for touches and this is its glass. */
                        fingers.append(Finger(touch: t, id: id, kind: spot.beside ? .neither : .screen))
                        if !spot.beside { henge_vm_ts_touch(id, 0, spot.x, spot.y, ts) }
                    }
                    if touchesLogged < 12 {
                        touchesLogged += 1
                        HengeLog.log("input", "touchscreen (\(gesture == .pointer ? "a pointer" : "touches")): finger \(id) down "
                                     + (spot.beside ? "beside the Mac's picture" : "at \(spot.x),\(spot.y) of 32767"))
                    }
                    continue
                }
                fingers.append(Finger(touch: t, id: id, kind: .pad))
                let (x, y) = sensor(t)
                henge_vm_touch(id, 0, x, y, ts)
                if touchesLogged < 12 {
                    touchesLogged += 1
                    HengeLog.log("input", "trackpad: finger \(id) down at \(x),\(y)")
                }
            }
            mostFingers = max(mostFingers, fingers.count)
            if fingers.count >= 4, fingers.contains(where: { $0.kind == .screen }) {
                /* Four fingers are Henge's (they show its controls), not the Mac's: lift the ones on its screen. */
                henge_vm_ts_release_all(Self.ms(touches.map(\.timestamp).max() ?? 0))
                for i in fingers.indices where fingers[i].kind == .screen { fingers[i].kind = .neither }
            }
            guard tapsClick else { return }
            if fingers.count >= 2 {
                cancelHold()
                if holding { /* a drag becomes a multi-finger gesture */
                    holding = false
                    henge_vm_mouse_button(0, 0)
                }
            } else {
                armHold()
            }
        }

        /// A finger comes down on the touchscreen as a pointer.
        private func pointerBegan(_ t: UITouch, id: Int32, x: Int32, y: Int32, beside: Bool, ts: UInt32) {
            switch pointing {
            case .idle where fingers.isEmpty && !beside:
                /* The first finger: the pointer goes to it. What it does there is settled by what comes next. */
                fingers.append(Finger(touch: t, id: id, kind: .point))
                pointing = .aiming
                aimStart = t.location(in: self)
                aim = (x, y)
                if Date().timeIntervalSince(lastTapTime) < Self.againTime,
                   abs(aimStart.x - lastTapStart.x) + abs(aimStart.y - lastTapStart.y) < Self.againDistance {
                    aim = lastTapAim /* a second tap: on the first */
                }
                pointAt = aim
                henge_vm_ts_pointer(aim.x, aim.y, 0)
                armPress()
            case .aiming:
                /* A second finger before the first did anything: a gesture for the Mac's trackpad, where
                   the pointer now is. Every finger goes down on the pad together. */
                cancelPress()
                pointing = .gesturing
                fingers.append(Finger(touch: t, id: id, kind: .pad))
                for i in fingers.indices {
                    fingers[i].kind = .pad
                    let (px, py) = sensor(fingers[i].touch)
                    henge_vm_touch(fingers[i].id, 0, px, py, ts)
                }
            case .gesturing:
                fingers.append(Finger(touch: t, id: id, kind: .pad))
                let (px, py) = sensor(t)
                henge_vm_touch(id, 0, px, py, ts)
            default:
                /* Beside the picture, or the gesture is a drag or over already: this finger is nothing to the Mac. */
                fingers.append(Finger(touch: t, id: id, kind: .neither))
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            var moved = false, movedOnScreen = false
            let ts = Self.ms(event?.timestamp ?? touches.first?.timestamp ?? 0)
            for t in touches where t.type != .indirectPointer {
                guard let i = fingers.firstIndex(where: { $0.touch == t }) else { continue }
                let now = t.location(in: self), before = t.previousLocation(in: self)
                travelled += abs(now.x - before.x) + abs(now.y - before.y)
                switch fingers[i].kind {
                case .pad:
                    let (x, y) = sensor(t)
                    henge_vm_touch(fingers[i].id, 1, x, y, ts)
                    moved = true
                case .screen:
                    if let spot = screenSpot(t) { /* off the picture's edge it stays at the edge */
                        henge_vm_ts_touch(fingers[i].id, 1, spot.x, spot.y, ts)
                        movedOnScreen = true
                    }
                case .point:
                    guard let spot = screenSpot(t) else { break }
                    if pointing == .aiming {
                        /* It moved off where it came down: a drag from there, with the button down. */
                        guard abs(now.x - aimStart.x) + abs(now.y - aimStart.y) >= Self.tapDistance else { break }
                        cancelPress()
                        pointing = .dragging
                        henge_vm_ts_pointer(aim.x, aim.y, 1)
                    }
                    if pointing == .dragging {
                        pointAt = (spot.x, spot.y)
                        henge_vm_ts_pointer(spot.x, spot.y, 1)
                    }
                case .neither:
                    break
                }
            }
            /* Moving means pointing or a gesture, not a tap or a press-to-drag. */
            if tapsClick && travelled >= Self.tapDistance && !holding { cancelHold() }
            /* One frame with every finger that moved, so the guest sees a gesture's
               fingers move together rather than one at a time. */
            if moved { henge_vm_touch_frame(ts) }
            if movedOnScreen { henge_vm_ts_frame(ts) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches, cancelled: false) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches, cancelled: true) }

        private func lift(_ touches: Set<UITouch>, cancelled: Bool) {
            var lifted: [Finger] = []
            fingers.removeAll { finger in
                guard touches.contains(finger.touch), finger.touch.type != .indirectPointer else { return false }
                freeIds.insert(finger.id)
                lifted.append(finger)
                return true
            }
            guard !lifted.isEmpty else { return }
            let ts = Self.ms(touches.map(\.timestamp).max() ?? 0)
            for finger in lifted {
                switch finger.kind {
                case .pad:
                    henge_vm_touch(finger.id, 2, 0, 0, ts)
                case .screen:
                    henge_vm_ts_touch(finger.id, 2, 0, 0, ts) /* it lifts where it last was */
                case .point:
                    cancelPress()
                    if pointing == .aiming && !cancelled {
                        /* It came down and went up where it was: a click there. */
                        henge_vm_ts_pointer(aim.x, aim.y, 1)
                        henge_vm_ts_pointer(aim.x, aim.y, 0)
                        buzz.impactOccurred()
                        lastTapTime = Date()
                        lastTapStart = aimStart
                        lastTapAim = aim
                    } else if pointing == .dragging {
                        henge_vm_ts_pointer(pointAt.x, pointAt.y, 0) /* the drag ends where the finger left */
                    }
                    pointing = .done
                case .neither:
                    break
                }
            }
            if pointing == .gesturing {
                /* A finger alone on a trackpad moves the pointer, which a finger on the screen must not: with
                   one left, the gesture is over for the Mac. */
                let onPad = fingers.indices.filter { fingers[$0].kind == .pad }
                if onPad.count == 1 {
                    henge_vm_touch(fingers[onPad[0]].id, 2, 0, 0, ts)
                    fingers[onPad[0]].kind = .neither
                }
            }
            guard fingers.isEmpty else { return } /* fingers still down: the gesture goes on */
            /* The whole gesture is over. */
            let quick = Date().timeIntervalSince(started) < Self.tapTime
            let still = travelled < Self.tapDistance
            if tapsClick {
                cancelHold()
                if holding {
                    holding = false
                    henge_vm_mouse_button(0, 0) /* let go of the drag */
                } else if quick && still {
                    if mostFingers == 1 { click(0) }      /* a tap is a left click */
                    else if mostFingers == 2 { click(1) } /* a two-finger tap is a right click */
                }
            }
            if gesture == .pointer {
                cancelPress()
                if pointing == .gesturing && mostFingers == 2 && quick && still && !cancelled {
                    /* A quick two-finger tap: a right click where the first finger pointed. */
                    henge_vm_ts_pointer(aim.x, aim.y, 2)
                    henge_vm_ts_pointer(aim.x, aim.y, 0)
                    buzz.impactOccurred()
                }
                pointing = .idle
            }
            if mostFingers >= 4, travelled < Self.tapDistance * 3, Date().timeIntervalSince(started) < Self.tapTime * 2 {
                NotificationCenter.default.post(name: Trackpad.revealTap, object: nil)
            }
            StickyKeys.shared.releaseAll()
        }

        /// A brief press of a mouse button: down then up.
        private func click(_ button: Int32) {
            henge_vm_mouse_button(button, 1)
            henge_vm_mouse_button(button, 0)
            buzz.impactOccurred()
        }

        /// A finger that stays put presses the left button down, so moving it drags.
        private func armHold() {
            cancelHold()
            let timer = Timer(timeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                guard let self, self.fingers.count == 1, self.travelled < Self.tapDistance else { return }
                self.holding = true
                henge_vm_mouse_button(0, 1)
                self.buzz.impactOccurred()
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
        }

        private func cancelHold() {
            holdTimer?.invalidate()
            holdTimer = nil
        }

        /// On the touchscreen as a pointer: a finger that stays where it came down is a right click there.
        private func armPress() {
            cancelPress()
            let timer = Timer(timeInterval: Self.pressTime, repeats: false) { [weak self] _ in
                guard let self, self.pointing == .aiming else { return }
                self.pointing = .done
                henge_vm_ts_pointer(self.aim.x, self.aim.y, 2)
                henge_vm_ts_pointer(self.aim.x, self.aim.y, 0)
                self.buzz.impactOccurred()
            }
            RunLoop.main.add(timer, forMode: .common)
            pressTimer = timer
        }

        private func cancelPress() {
            pressTimer?.invalidate()
            pressTimer = nil
        }
    }
}

/// One mouse button you can hold: down when touched, up when let go.
struct MouseButton: View {
    let title: String
    let button: Int32
    @State private var down = false

    var body: some View {
        Text(title)
            .font(.system(size: 15))
            .foregroundStyle(down ? Desk.text : Desk.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(down ? Desk.raised : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        henge_vm_mouse_button(button, 1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        down = false
                        henge_vm_mouse_button(button, 0)
                        StickyKeys.shared.releaseAll()
                    }
            )
            .accessibilityLabel(title)
    }
}