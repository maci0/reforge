#ifndef STANDBY_PMIC_DATA_H
#define STANDBY_PMIC_DATA_H
#include <stdint.h>

struct standby_pmic_range {
    uint32_t minimum_uv, first_code, last_code, step_uv;
};
struct standby_pmic_entry {
    uint32_t minimum_uv, maximum_uv, step_uv;
    uint32_t voltage_reg, voltage_bits, control_reg, control_mask;
    uint32_t enable_value, disable_value;
    const struct standby_pmic_range *ranges;
    int32_t range_count;
    uint32_t reserved;
};
struct standby_pmic_device {
    uint32_t address, reserved, count;
    const struct standby_pmic_entry *entries;
};
extern const struct standby_pmic_range standby_pmic_ranges_1[2];
extern const struct standby_pmic_range standby_pmic_ranges_2[3];
extern const struct standby_pmic_range standby_pmic_ranges_3[2];
extern const struct standby_pmic_entry standby_pmic_entries[16];
extern struct standby_pmic_device standby_pmic_device;
#endif
