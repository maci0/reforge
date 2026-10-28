#include "pmic.h"
int standby_pmic_read(const uint8_t *device, unsigned reg, uint8_t *value)
{
    return standby_twi_transfer(0, *device, reg, value);
}
int standby_pmic_write(const uint8_t *device, unsigned reg, uint8_t *value)
{
    return standby_twi_transfer(1, *device, reg, value);
}
int standby_pmic_update(const uint8_t *device, unsigned reg, unsigned value, unsigned mask)
{
    uint8_t old = 0;
    int ret = standby_pmic_read(device, reg, &old);
    if (ret) return ret;
    /* Compare the original unmasked request before changing the register. */
    if ((old & mask) == value) return ret;
    old &= ~mask;
    value &= mask;
    old |= value;
    return standby_pmic_write(device, reg, &old);
}
