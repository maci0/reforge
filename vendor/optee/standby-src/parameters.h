#ifndef STANDBY_PARAMETERS_H
#define STANDBY_PARAMETERS_H
#include <stdint.h>

/* The BSP dram_v2.h defines this 24-word prefix; the extension ABI is partly unknown. */
struct standby_dram_parameters {
    uint32_t clock, type, zq, odt;
    uint32_t geometry1, geometry2;
    uint32_t mode[4];
    uint32_t timing[14];
};
struct standby_parameters {
    struct standby_dram_parameters dram;
    /* shortcut: extension meanings remain unrecovered, name slots when caller-ABI evidence identifies them. */
    uint32_t extension[36];
};
extern struct standby_parameters standby_parameters;
#endif
