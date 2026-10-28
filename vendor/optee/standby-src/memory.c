#include "memory.h"
void standby_dram_master_enable(void)
{
    volatile uint32_t *registers = (volatile uint32_t *)0x03102000;
    registers[8] = 0xffffffff;
    registers[9] = 0xff;
    registers[10] = 0xffff;
}
void standby_dram_master_disable(void)
{
    volatile uint32_t *registers = (volatile uint32_t *)0x03102000;
    registers[8] = 1;
    registers[9] = 0;
    registers[10] = 0;
}
uint32_t standby_dram_checksum(const uint32_t *parameters)
{
    uint32_t *cursor = (uint32_t *)(uintptr_t)parameters[33];
    uint32_t end = parameters[33] + parameters[34];
    uint32_t checksum = 0;
    /* Integer comparison preserves the original 32-bit end-address wrap behavior. */
    while ((uintptr_t)cursor < end)
        checksum += *cursor++;
    return checksum;
}
