#include "clock.h"

const uint32_t standby_clock_registers[8]
__attribute__((section(".rodata.standby_clock_registers"))) = {
    0x02001000, 0x02001010, 0x02001020, 0x02001040,
    0x02001048, 0x02001058, 0x02001078, 0x02001080,
};
struct standby_clock_context standby_clock_contexts[6]
__attribute__((section(".data.standby_clock_contexts"))) = {
    {0x02001500, 0, 0, 0, 0},
    {0x02001510, 0, 0, 0, 0},
    {0x02001520, 0, 0, 0, 0},
    {0x02001524, 0, 0, 0, 0},
    {0x07010000, 0, 0, 0, 0},
    {0x0701000c, 0, 0, 0, 0},
};
const uint32_t standby_sram_parameters_address
__attribute__((section(".rodata.standby_sram_parameters_address"))) = 0x20000;
uint32_t standby_clock_saved_aux
__attribute__((section(".bss.standby_clock_saved_aux")));

_Static_assert(sizeof(struct standby_clock_context) == 8, "ARM clock context layout");
