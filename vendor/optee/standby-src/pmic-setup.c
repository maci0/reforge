#include "pmic-setup.h"
#include "pmic.h"
#include "pmic-data.h"
#include "twi.h"

int standby_pmic_prepare(void)
{
    uint8_t value = 0xff;
    standby_pmic_write((const uint8_t *)&standby_pmic_device, 0x48, &value);
    standby_pmic_write((const uint8_t *)&standby_pmic_device, 0x49, &value);
    standby_pmic_write((const uint8_t *)&standby_pmic_device, 0x4a, &value);
    value = 0x1d;
    return standby_pmic_write((const uint8_t *)&standby_pmic_device, 0x26, &value);
}
int standby_pmic_read_id(unsigned address, uint8_t *value)
{
    return standby_twi_transfer(0, address, 3, value);
}
int standby_pmic_initialize(uint32_t *slot, uint32_t address, unsigned controller)
{
    *slot = address;
    standby_twi_init(controller);
    return 0;
}
