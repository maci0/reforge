#include "twi.h"

struct standby_twi_state standby_twi_state;
volatile uint32_t * const standby_twi_bases[5] = {
    (void *)0x02502000, (void *)0x02502400, (void *)0x02502800,
    (void *)0x02502c00, (void *)0x02503000,
};

int standby_twi_init(unsigned index)
{
    volatile uint32_t *r = standby_twi_bases[index];
    standby_twi_state.divider = r[5];
    standby_twi_state.control = r[3] & 0x80;
    r[5] = 0x28;
    standby_twi_state.base = r;
    r[6] |= 1;
    while (r[6] & 1) {}
    return 0;
}
void standby_twi_set_divider(void)
{
    standby_twi_state.base[5] = 0x28;
}
int standby_twi_restore(void)
{
    volatile uint32_t *r = standby_twi_state.base;
    r[6] |= 1;
    r[5] = standby_twi_state.divider;
    r[3] |= standby_twi_state.control;
    return 0;
}
