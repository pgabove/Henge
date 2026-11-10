#include "timer.h"

#include "sysreg.h"

static uint64_t one(HvGic *g, int c, int ppi, uint64_t ctl, uint64_t cval, uint64_t now, uint64_t offset) {
    int enabled = (ctl & 1) && !(ctl & 2);
    int fired = enabled && now - offset >= cval;
    hv_gicv3_set_ppi(g, c, ppi, fired);
    /* Deadline in host counter units; nothing to wait for if off or already firing. */
    return enabled && !fired ? cval + offset : 0;
}

uint64_t hv_timer_update(HvGic *g, HvCpu *cpu) {
    uint64_t now = hv_counter();
    uint64_t v = one(g, (int)cpu->index, HV_PPI_VTIMER, cpu->cntv_ctl, cpu->cntv_cval, now, cpu->cntvoff);
    uint64_t p = one(g, (int)cpu->index, HV_PPI_PTIMER, cpu->cntp_ctl, cpu->cntp_cval, now, 0);
    uint64_t due = !v ? p : !p ? v : v < p ? v : p;
    /* Those are the guest's counter values. The dispatcher compares against the host's clock, which is
       ahead of the guest's by the time the machine has been held paused. */
    return due ? due + hv_time_held : 0;
}
