#ifndef REFORGE_STANDBY_DELAY_H
#define REFORGE_STANDBY_DELAY_H
#include <stdint.h>

void standby_delay_cycles(uint32_t count);
void standby_delay_repeat17(uint32_t count);
/* Original scaling conventions; actual elapsed-time calibration is unverified. */
void standby_delay_us(uint32_t count);
void standby_delay_ms(uint32_t count);

#endif
