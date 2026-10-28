#ifndef STANDBY_CLOCK_H
#define STANDBY_CLOCK_H
#include <stdint.h>

struct standby_clock_context {
    uint32_t address;
    uint8_t source, divider_n, divider_m, saved;
};
extern const uint32_t standby_clock_registers[8];
extern struct standby_clock_context standby_clock_contexts[6];
extern uint32_t standby_clock_saved_aux;
extern const uint32_t standby_sram_parameters_address;
void standby_clock_select(unsigned mode);
void standby_clock_enter(void);
void standby_clock_leave(void);
#endif
