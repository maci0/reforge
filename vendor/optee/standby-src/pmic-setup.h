#ifndef STANDBY_PMIC_SETUP_H
#define STANDBY_PMIC_SETUP_H
#include <stdint.h>

int standby_pmic_prepare(void);
int standby_pmic_group_control(unsigned reg, unsigned flags);
int standby_pmic_read_id(unsigned address, uint8_t *value);
int standby_pmic_initialize(uint32_t *slot, uint32_t address, unsigned controller);
#endif
