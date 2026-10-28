#ifndef STANDBY_DRAM_STATE_H
#define STANDBY_DRAM_STATE_H
#include <stdint.h>

extern uint32_t standby_saved_sp;
extern uint32_t standby_dram_state[106];
void standby_dram_restore_lanes(void);
int standby_dram_configure_modulation(const uint32_t *parameters, volatile uint32_t *control,
                                     volatile uint32_t *modulation);
unsigned standby_dram_program_pll(unsigned alternate, const uint32_t *parameters);
void standby_dram_restore_common_config(void);
void standby_dram_configure_tpr5_6(const uint32_t *parameters);
int standby_dram_resume_core(uint32_t *parameters);
int standby_dram_resume(unsigned alternate, uint32_t *parameters);
int standby_dram_suspend(void);
int standby_dram_resume_default(uint32_t *parameters);
int standby_dram_suspend_all(const uint32_t *parameters);
int standby_dram_resume_all(uint32_t *parameters);
#endif
