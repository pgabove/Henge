#ifndef HENGEVM_AUDIO_MAC_H
#define HENGEVM_AUDIO_MAC_H

#include "virtio_snd.h"

/* Play the guest's virtio-snd output on the Mac's default output device. */
void hv_audio_attach(HvVirtioSnd *d);
/* While the machine is paused (hv_vm_pause): stop the output, so a paused Mac that was playing does not keep
   the app awake to play silence; and start it again if it was playing. From the thread that pauses, with the
   CPUs parked. */
void hv_audio_hold(int hold);

#endif
