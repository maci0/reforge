#ifndef STANDBY_PMIC_H
#define STANDBY_PMIC_H
#include <stdint.h>

int standby_twi_transfer(unsigned write, unsigned address, unsigned reg, uint8_t *value);
int standby_pmic_read(const uint8_t *device, unsigned reg, uint8_t *value);
int standby_pmic_write(const uint8_t *device, unsigned reg, uint8_t *value);
int standby_pmic_update(const uint8_t *device, unsigned reg, unsigned value, unsigned mask);
#endif
