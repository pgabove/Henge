#ifndef HENGEVM_XHCI_H
#define HENGEVM_XHCI_H

#include <pthread.h>

#include "pcie.h"

/* An xHCI USB host controller (xHCI 1.0, one interrupter, 32-byte contexts,
   INTx) with up to three USB HID devices: a boot keyboard on port 1 and a Magic
   Trackpad 2 on port 2: what Virtualization.framework gives a macOS guest as
   its "Virtual USB Keyboard", plus Apple's multitouch pad, so the guest's
   own gesture engine sees a real trackpad. Port 3 is empty unless the host asked
   for a touchscreen (hv_xhci_set_touchscreen): then it holds what a USB touch
   monitor's panel is to a computer, a HID multi-touch touchscreen that is a
   pointer on the screen until the host asks it for touches. Changes come from
   the host UI on any thread (hv_xhci_key, hv_xhci_touch, hv_xhci_ts_touch,
   hv_xhci_ts_pointer); the CPU thread delivers them (hv_xhci_poll). */
#define HV_XHCI_SLOTS 8
#define HV_XHCI_PORTS 3
#define HV_XHCI_DEVICES 3
#define HV_XHCI_INTRS 4
#define HV_XHCI_EPS 32 /* device context index 1..31 */
#define HV_XHCI_REPORTS 256

/* The Magic Trackpad 2's sensor, in its own units (a ~160 x 115 mm pad).
   hv_xhci_touch takes coordinates in these ranges. */
#define HV_TP_SENSOR_X 8134
#define HV_TP_SENSOR_Y 5206
#define HV_TP_FINGERS 10
#define HV_TP_REPORTS 64
#define HV_TP_REPORT_LEN (12 + 9 * HV_TP_FINGERS) /* report ID 2: 12-byte prefix, N x 9-byte fingers */

/* The touchscreen, as the HID multi-touch digitizer every USB touch monitor is: coordinates are
   0..HV_TS_MAX across the Mac's screen, left to right and top to bottom. */
#define HV_TS_MAX 32767
#define HV_TS_FINGERS 5
#define HV_TS_REPORTS 64
#define HV_TS_REPORT_LEN (1 + 6 * HV_TS_FINGERS + 2 + 1) /* report ID 1: six bytes a contact, the scan time, the contact count */
#define HV_TS_POINTER_LEN 6                              /* report ID 3: the buttons, X and Y */
/* What it reports as (hv_xhci_ts_mode). */
#define HV_TS_MODE_NONE 0    /* there is none, or the guest has not set it up */
#define HV_TS_MODE_POINTER 1 /* a pointer at a place on the screen, with buttons (report 3) */
#define HV_TS_MODE_TOUCH 2   /* fingers (report 1): the guest asked for them */

typedef struct HvXhciRing {
    uint64_t dequeue; /* guest PA of the next TRB */
    int ccs;          /* consumer cycle state */
} HvXhciRing;

typedef struct HvXhci {
    HvPciDev pci;
    HvMachine *m;
    /* operational */
    uint32_t usbcmd, usbsts, dnctrl, config;
    uint64_t dcbaap;
    HvXhciRing cmd;
    int cmd_running;
    uint32_t portsc[HV_XHCI_PORTS];
    /* interrupters and their event rings (macOS's driver wants at least three) */
    struct HvXhciIntr {
        uint32_t iman, imod, erstsz;
        uint64_t erstba, erdp;
        uint64_t seg_base;  /* current event ring segment */
        uint32_t seg_size, seg_index, index;
        int pcs;
    } intr[HV_XHCI_INTRS];
    /* device slots: -1 until the device on the slot's port is addressed */
    int slot_used[HV_XHCI_SLOTS + 1];
    struct HvXhciSlot {
        int dev;         /* 0 keyboard, 1 trackpad, 2 touchscreen, -1 none */
        int configured;
        HvXhciRing ep[HV_XHCI_EPS];
        int ep_running[HV_XHCI_EPS];
    } slots[HV_XHCI_SLOTS + 1];
    /* keyboard reports waiting for an IN transfer (8 bytes each) */
    pthread_mutex_t mu;
    uint8_t reports[HV_XHCI_REPORTS][8];
    uint32_t rhead, rtail;
    uint8_t state[8];      /* modifiers, reserved, six keys: the current report */
    uint64_t delivered;
    /* Magic Trackpad 2: the fingers on the pad and their reports (Apple
       multitouch format, report ID 2: 12-byte prefix plus 9 bytes a finger). */
    struct HvTpFinger {
        int in;
        int id;        /* the report's 4-bit touch ID, 1..15 */
        int x, y;      /* sensor coordinates, 0..HV_TP_SENSOR_X/Y */
        uint8_t state; /* the report's 3-bit state: 0 none, 3 near, 4 contact, 7 stop */
    } tp_fingers[HV_TP_FINGERS];
    int tp_button;     /* the pad's full press (report byte 1, bit 0) */
    uint32_t tp_ts;    /* the report timestamp, one per report */
    uint8_t tp_reports[HV_TP_REPORTS][HV_TP_REPORT_LEN];
    uint8_t tp_rlen[HV_TP_REPORTS];
    uint32_t tp_rhead, tp_rtail;
    int tp_mt;         /* the guest switched us to multitouch mode (feature report 2) */
    uint64_t tp_delivered;
    uint32_t tp_reqs;   /* control requests logged, capped */
    uint32_t tp_db;     /* doorbells logged, capped */
    uint32_t tp_multi_logs; /* multi-finger deliveries logged, capped */
    uint8_t tp_f1[8];   /* feature report 1: the header for the selected sensor register */
    int tp_f1_len;
    /* The touchscreen on port 3, when there is one: the fingers on the Mac's screen and their
       reports (report ID 1: the contacts in use first, then the scan time and how many there are). */
    int ts_present;
    struct HvTsContact {
        int in;        /* goes in the next report */
        int id;        /* contact identifier, 1..15, the same for as long as the finger stays down */
        int x, y;      /* 0..HV_TS_MAX */
        int down;      /* touching; 0 in the one report that says the finger lifted */
    } ts_contacts[HV_TS_FINGERS];
    uint32_t ts_scan;      /* the last report's scan time, in 100 us (the report carries its low 16 bits) */
    int ts_touches;        /* the guest set the device mode to touches (or HV_TS_MODE did): report 1, not 3 */
    int ts_mode_fixed;     /* HV_TS_MODE chose: what the guest asks for changes nothing */
    int ts_px, ts_py, ts_buttons; /* as a pointer: where it last pointed and the buttons held */
    int ts_tail_move;      /* the newest waiting report is a pointer's move (no button changed in it): the next move may replace it */
    uint8_t ts_reports[HV_TS_REPORTS][HV_TS_REPORT_LEN];
    uint8_t ts_rlen[HV_TS_REPORTS];
    uint32_t ts_rhead, ts_rtail;
    uint32_t ts_guest_down; /* bit per contact identifier: the guest was last told this finger is down */
    uint64_t ts_delivered;
    uint32_t ts_reqs;       /* control requests logged, capped */
    uint32_t ts_drops;      /* touches dropped because nothing reads the touchscreen, logged capped */
} HvXhci;

HvXhci *hv_xhci_create(HvMachine *m, HvPcie *bus);
/* Any thread: a key went down or up (HID usage page 7 usage, e.g. 4 = A; 0xe0-0xe7 are modifiers). */
void hv_xhci_key(HvXhci *x, uint8_t usage, int down);
/* The same, by Linux input key code (what the host UI produces). */
void hv_xhci_key_linux(HvXhci *x, uint16_t code, int down);
/* Any thread: a Magic Trackpad 2 touch. phase: 0 down, 1 move, 2 up. id: a
   stable 1..15 for this touch; x, y in sensor units (HV_TP_SENSOR_*). Down and up
   report at once; a move only updates the finger, and hv_xhci_touch_frame commits
   one report for all the fingers that moved together. ts_ms is the touch sample's
   own clock (ms); the guest divides position deltas by timestamp deltas to get
   speed, so it must be the sample time, not the moment we happen to process it. */
void hv_xhci_touch(HvXhci *x, int id, int phase, int px, int py, uint32_t ts_ms);
/* Any thread: send one frame with every finger's current state (ends a move batch),
   stamped with the touch sample's own clock (ms). */
void hv_xhci_touch_frame(HvXhci *x, uint32_t ts_ms);
/* Any thread: the pad's full press (a click), down or up. */
void hv_xhci_touch_button(HvXhci *x, int down);
/* Before hv_xhci_create: whether the Mac gets the touchscreen on port 3, and the size in mm of the
   screen it covers (0, 0: unknown). */
void hv_xhci_set_touchscreen(int on, uint32_t width_mm, uint32_t height_mm);
/* Any thread: a finger on the touchscreen. phase: 0 down, 1 move, 2 up. id: a stable 1..15 for this
   touch; x, y 0..HV_TS_MAX across the Mac's screen. As with the trackpad, down and up report at
   once and a move only updates the finger: hv_xhci_ts_frame commits one report for all the fingers
   that moved together. ts_ms is the touch sample's own clock (ms). */
void hv_xhci_ts_touch(HvXhci *x, int id, int phase, int px, int py, uint32_t ts_ms);
void hv_xhci_ts_frame(HvXhci *x, uint32_t ts_ms);
/* Any thread: every finger is off the touchscreen (the session lost its touches). */
void hv_xhci_ts_release_all(HvXhci *x, uint32_t ts_ms);
/* Any thread: the touchscreen as a pointer (what it is to a host that has not asked for touches, which
   is every macOS so far): it points at px, py with these buttons down (bit 0 left, 1 right, 2 middle). */
void hv_xhci_ts_pointer(HvXhci *x, int px, int py, int buttons);
/* Any thread: HV_TS_MODE_*, so the host UI knows whether to send fingers or a pointer. */
int hv_xhci_ts_mode(HvXhci *x);
/* CPU thread: hand waiting reports to the guest. */
void hv_xhci_poll(HvXhci *x);

#endif
