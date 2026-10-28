#include "pmic-data.h"

const struct standby_pmic_range standby_pmic_ranges_3[2]
__attribute__((section(".rodata.standby_pmic_ranges_3"))) = {
    {500000, 0, 70, 10000},
    {1220000, 71, 102, 20000},
};
const struct standby_pmic_range standby_pmic_ranges_2[3]
__attribute__((section(".rodata.standby_pmic_ranges_2"))) = {
    {500000, 0, 70, 10000},
    {1220000, 71, 87, 20000},
    {1600000, 88, 106, 100000},
};
const struct standby_pmic_range standby_pmic_ranges_1[2]
__attribute__((section(".rodata.standby_pmic_ranges_1"))) = {
    {500000, 0, 70, 10000},
    {1220000, 71, 87, 20000},
};
const struct standby_pmic_entry standby_pmic_entries[16]
__attribute__((section(".rodata.standby_pmic_entries"))) = {
    {1500000, 3400000, 100000, 0x82, 5, 0x80, 0x01, 0, 0, 0, 0, 0},
    {0, 0, 0, 0x83, 7, 0x80, 0x02, 0, 0, standby_pmic_ranges_1, 2, 0},
    {0, 0, 0, 0x84, 7, 0x80, 0x04, 0, 0, standby_pmic_ranges_2, 3, 0},
    {0, 0, 0, 0x85, 7, 0x80, 0x08, 0, 0, standby_pmic_ranges_3, 2, 0},
    {1400000, 3700000, 100000, 0x86, 5, 0x80, 0x10, 0, 0, 0, 0, 0},
    {1800000, 1800000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
    {1800000, 1800000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
    {500000, 3500000, 100000, 0x92, 5, 0x90, 0x01, 0, 0, 0, 0, 0},
    {500000, 3500000, 100000, 0x93, 5, 0x90, 0x02, 0, 0, 0, 0, 0},
    {500000, 3500000, 100000, 0x94, 5, 0x90, 0x04, 0, 0, 0, 0, 0},
    {500000, 3500000, 100000, 0x95, 5, 0x90, 0x08, 0, 0, 0, 0, 0},
    {500000, 3500000, 100000, 0x96, 5, 0x90, 0x10, 0, 0, 0, 0, 0},
    {500000, 3500000, 100000, 0x97, 5, 0x90, 0x20, 0, 0, 0, 0, 0},
    {500000, 3500000, 100000, 0x99, 5, 0x90, 0x80, 0, 0, 0, 0, 0},
    {500000, 3500000, 100000, 0x9a, 5, 0x91, 0x01, 0, 0, 0, 0, 0},
    {500000, 3500000, 100000, 0x98, 5, 0x90, 0x40, 0, 0, 0, 0, 0},
};
struct standby_pmic_device standby_pmic_device
__attribute__((section(".data.standby_pmic_device"))) = {
    0, 0, 16, standby_pmic_entries,
};

_Static_assert(sizeof(struct standby_pmic_range) == 16, "ARM range layout");
_Static_assert(sizeof(struct standby_pmic_entry) == 48, "ARM entry layout");
_Static_assert(sizeof(struct standby_pmic_device) == 16, "ARM device layout");
