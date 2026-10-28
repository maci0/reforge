#ifndef REFORGE_STANDBY_MEMORY_H
#define REFORGE_STANDBY_MEMORY_H
#include <stdint.h>

void standby_dram_master_enable(void);
void standby_dram_master_disable(void);
/* Parameters[33]/[34] are the original start address / byte count fields. */
uint32_t standby_dram_checksum(const uint32_t *parameters);

#endif
