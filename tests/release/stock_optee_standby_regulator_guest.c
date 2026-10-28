/* Test-only TWI recorder for the recovered regulator assembly and real tables. */
#define _GNU_SOURCE
#include <signal.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>
#include "regulator.h"
#include "pmic.h"

static unsigned old, written, calls, reads, writes, bad, reg_expected;
static int read_error, write_error;
static unsigned fault_expected;
int standby_twi_transfer(unsigned write, unsigned address, unsigned reg, uint8_t *value) {
    if (address != 0x34 || reg != reg_expected || !value || write > 1) bad = 1;
    ++calls;
    if (!write) { ++reads; *value = old; return read_error; }
    ++writes; written = *value;
    return write_error;
}
static void reset(unsigned value, unsigned reg) {
    old = value; written = 0x100; reg_expected = reg;
    calls = reads = writes = bad = 0;
    read_error = write_error = 0;
}
static void fault(int signal, siginfo_t *info, void *context) {
    (void)context;
    _exit(signal == SIGSEGV && (uintptr_t)info->si_addr == fault_expected ? 0 : 90);
}
extern int stack_probe(void);
__asm__(".text\n.arm\n.global stack_probe\nstack_probe:\n"
        "push {r4,r5,lr}\nmov r4,sp\nbl standby_stack_switch\n"
        "mov r5,sp\nbl standby_stack_restore\n"
        "cmp sp,r4\nmovne r0,#1\nbne 1f\n"
        "movw r1,#0x7ff0\nmovt r1,#2\ncmp r5,r1\n"
        "moveq r0,#0\nmovne r0,#2\n1: pop {r4,r5,pc}\n");
static int set_case(struct standby_pmic_device *dev, unsigned index, unsigned uv,
                    unsigned byte, unsigned expected_code, int result_expected, unsigned writes_expected) {
    const struct standby_pmic_entry *entry = &dev->entries[index];
    unsigned mask = (1u << entry->voltage_bits) - 1;
    int result;
    reset(byte, (uint8_t)entry->voltage_reg);
    result = standby_regulator_set_voltage(dev, 1u << index, uv);
    if (result != result_expected || writes != writes_expected || bad) return 1;
    if (result_expected == -1) return calls != 0;
    if (reads != 1 || calls != 1 + writes_expected) return 2;
    return writes_expected && written != (uint8_t)((byte & ~mask) | expected_code);
}
int main(int argc, char **argv) {
    struct standby_pmic_device dev = standby_pmic_device;
    struct standby_pmic_entry custom = {0};
    struct standby_pmic_device custom_dev = {0x34, 0, 0, &custom};
    unsigned i, code;
    dev.address = 0x34;
    if (argc > 1) {
        struct sigaction action = {0};
        action.sa_sigaction = fault; action.sa_flags = SA_SIGINFO;
        sigemptyset(&action.sa_mask);
        if (sigaction(SIGSEGV, &action, 0)) return 80;
        switch (argv[1][0]) {
        case 's': fault_expected = 16; standby_regulator_set_voltage(&dev, 0, 0); break;
        case 'g': fault_expected = 12; standby_regulator_get_voltage(&dev, 0); break;
        case 'e': fault_expected = 28; standby_regulator_set_enabled(&dev, 0, 1); break;
        case 'q': fault_expected = 20; standby_regulator_get_enabled(&dev, 0); break;
        default: return 81;
        }
        return 82; /* Invalid selection must retain its observed null read. */
    }
    if (mmap((void *)0x27000, 4096, PROT_READ | PROT_WRITE,
             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) != (void *)0x27000 || stack_probe()) return 1;
    for (i = 0; i < 16; ++i) for (code = 0; code < 256; ++code) {
        const struct standby_pmic_entry *entry = &dev.entries[i];
        unsigned raw = code & ((1u << entry->voltage_bits) - 1);
        int expected = -1;
        unsigned r;
        if (!entry->ranges) expected = entry->minimum_uv + raw * entry->step_uv;
        else for (r = 0; r < (unsigned)entry->range_count; ++r) {
            const struct standby_pmic_range *range = &entry->ranges[r];
            if (raw >= range->first_code && raw <= range->last_code) {
                expected = range->minimum_uv + (raw - range->first_code) * range->step_uv; break;
            }
        }
        reset(code, (uint8_t)entry->voltage_reg);
        if (standby_regulator_get_voltage(&dev, 1u << i) != expected || calls != 1 || writes || bad) return 2;
        reset(code, (uint8_t)entry->control_reg);
        if (standby_regulator_get_enabled(&dev, 1u << i) != !!(code & entry->control_mask) || calls != 1 || bad) return 3;
    }
    if (set_case(&dev, 0, 1500000, 0xa0, 0, 0, 0) ||
        set_case(&dev, 0, 1500001, 0xa0, 1, 0, 1) ||
        set_case(&dev, 0, 3400000, 0xa0, 19, 0, 1) ||
        set_case(&dev, 0, 3499999, 0xa0, 20, 0, 1) ||
        set_case(&dev, 0, 10000000, 0, 85, 0, 1)) return 4;
    if (set_case(&dev, 1, 500000, 0, 0, 0, 0) ||
        set_case(&dev, 1, 510001, 0, 1, 0, 1) ||
        set_case(&dev, 1, 1200000, 0, 70, 0, 1) ||
        set_case(&dev, 1, 1210000, 0, 0, -1, 0) ||
        set_case(&dev, 1, 1220000, 0, 71, 0, 1) ||
        set_case(&dev, 1, 1239999, 0, 71, 0, 1) ||
        set_case(&dev, 1, 1540000, 0, 87, 0, 1) ||
        set_case(&dev, 1, 1540001, 0, 0, -1, 0)) return 5;
    if (set_case(&dev, 2, 1550000, 0, 0, -1, 0) ||
        set_case(&dev, 2, 1600001, 0, 88, 0, 1) ||
        set_case(&dev, 2, 3400000, 0, 106, 0, 1) ||
        set_case(&dev, 2, 3500000, 0, 0, -1, 0) ||
        set_case(&dev, 3, 1840000, 0, 102, 0, 1) ||
        set_case(&dev, 3, 1840001, 0, 0, -1, 0) ||
        set_case(&dev, 5, 1000000, 0xff, 0, 0, 0)) return 6;
    reset(0, 0x82); read_error = -7;
    if (standby_regulator_set_voltage(&dev, 1, 1600000) != -7 || calls != 1 || writes) return 7;
    reset(0, 0x82); write_error = -19;
    if (standby_regulator_set_voltage(&dev, 1, 1600000) != -19 || calls != 2 || written != 1) return 8;
    reset(0, 0x82); read_error = -7;
    if (standby_regulator_get_voltage(&dev, 1) != -7 || calls != 1) return 9;
    reset(0, 0x80); read_error = -7;
    if (standby_regulator_get_enabled(&dev, 1) != -7 || calls != 1) return 10;
    reset(0xa0, 0x80);
    if (standby_regulator_set_enabled(&dev, 1, 1) || written != 0xa1 || calls != 2 || bad) return 11;
    reset(0xa0, 0x80);
    if (standby_regulator_set_enabled(&dev, 1, 0) || written != 0xa0 || calls != 2 || bad) return 12;
    reset(0xa1, 0x80);
    if (standby_regulator_set_enabled(&dev, 1, 99) || calls != 1 || writes || bad) return 13;
    custom.control_reg = 0x91; custom.control_mask = 6; custom.enable_value = 2; custom.disable_value = 4;
    reset(0x40, 0x91);
    if (standby_regulator_set_enabled(&custom_dev, 1, 1) || written != 0x42 || bad) return 14;
    reset(2, 0x91);
    if (standby_regulator_get_enabled(&custom_dev, 1) != 1 || bad) return 15;
    reset(0x42, 0x91);
    if (standby_regulator_get_enabled(&custom_dev, 1) != 0 || bad) return 16;
    custom.enable_value = 0;
    reset(4, 0x91);
    if (standby_regulator_get_enabled(&custom_dev, 1) != 0 || bad) return 17;
    reset(0x44, 0x91);
    if (standby_regulator_get_enabled(&custom_dev, 1) != 1 || bad) return 18;
    custom.ranges = standby_pmic_ranges_1; custom.range_count = -1;
    reset(0, 0);
    if (standby_regulator_set_voltage(&custom_dev, 1, 500000) != -1 || calls) return 19;
    if (standby_regulator_get_voltage(&custom_dev, 1) != -1 || calls != 1) return 20;
    return 0;
}
