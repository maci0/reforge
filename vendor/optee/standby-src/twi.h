#ifndef STANDBY_TWI_H
#define STANDBY_TWI_H
#include <stdint.h>

struct standby_twi_state {
    volatile uint32_t *base;
    uint32_t divider, control;
};
extern struct standby_twi_state standby_twi_state;
extern volatile uint32_t * const standby_twi_bases[5];
int standby_twi_init(unsigned index);
void standby_twi_set_divider(void);
int standby_twi_restore(void);
int standby_twi_stop(void);
int standby_twi_transfer(unsigned write, unsigned address, unsigned reg, uint8_t *value);
#endif
