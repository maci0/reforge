#ifndef STANDBY_REGULATOR_H
#define STANDBY_REGULATOR_H
#include "pmic-data.h"

int standby_regulator_set_voltage(const struct standby_pmic_device *device, unsigned flags, unsigned uv);
int standby_regulator_get_voltage(const struct standby_pmic_device *device, unsigned flags);
int standby_regulator_set_enabled(const struct standby_pmic_device *device, unsigned flags, unsigned enabled);
int standby_regulator_get_enabled(const struct standby_pmic_device *device, unsigned flags);
#endif
