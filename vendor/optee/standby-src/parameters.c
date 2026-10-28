#include "parameters.h"

struct standby_parameters standby_parameters
__attribute__((section(".data.standby_parameters"))) = {
    .dram = {
        .clock = 672, .type = 3, .zq = 0x003f3fdd, .odt = 1,
        .geometry1 = 0x10f41000, .geometry2 = 0x00001200,
        .mode = {0x1a50, 0x40, 0x10, 0},
        .timing = {0x04e214ea, 0x004214ad, 0x10a75030, 0, 0, 0, 0,
                   0, 0, 0, 0, 0, 0xa8, 0x823},
    },
};
_Static_assert(sizeof(struct standby_dram_parameters) == 96, "BSP DRAM prefix");
_Static_assert(sizeof(struct standby_parameters) == 240, "Observed parameter/entry ABI");
