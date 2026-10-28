/* Test-only TWI/init backends; setup, selector and register helpers are unmodified. */
#include <stdint.h>
#include "pmic-setup.h"
#include "pmic-data.h"
#include "pmic.h"

static unsigned old, written, calls, writes, bad, expected_address, expected_reg;
static unsigned prepare_mode, init_calls, init_index, init_bad;
static uint32_t *init_slot;
static uint32_t init_value;
static int read_error, write_error, init_error, prepare_status[4];
int standby_twi_transfer(unsigned write, unsigned address, unsigned reg, uint8_t *value) {
    unsigned n = calls++;
    if (!value || write > 1 || address != expected_address) bad = 1;
    if (prepare_mode) {
        static const unsigned regs[] = {0x48, 0x49, 0x4a, 0x26};
        if (n >= 4 || !write || reg != regs[n] || *value != (n == 3 ? 0x1d : 0xff)) {
            bad = 2; return -99;
        }
        ++writes;
        return prepare_status[n];
    }
    if (reg != expected_reg) bad = 3;
    if (!write) { *value = old; return read_error; }
    written = *value; ++writes;
    return write_error;
}
int standby_twi_init(unsigned index) {
    ++init_calls;
    if (index != init_index || *init_slot != init_value) init_bad = 1;
    return init_error;
}
static void reset(unsigned byte, unsigned reg) {
    old = byte; expected_reg = reg; expected_address = 0x34;
    written = 0x100; calls = writes = bad = prepare_mode = 0;
    read_error = write_error = 0;
}
int main(void) {
    static const unsigned controls[] = {0x80, 0x90, 0x91, 0x190};
    static const unsigned bytes[] = {0, 0xff, 0xa5, 0x5a};
    unsigned flags, c, b, i;
    uint8_t value;
    standby_pmic_device.address = 0x34;
    reset(0, 0); prepare_mode = 1;
    prepare_status[0] = -7; prepare_status[1] = -9;
    prepare_status[2] = -11; prepare_status[3] = -13;
    if (standby_pmic_prepare() != -13 || calls != 4 || writes != 4 || bad) return 1;
    reset(0, 0); prepare_mode = 1; prepare_status[3] = 0;
    if (standby_pmic_prepare() || calls != 4 || bad) return 2;
    for (flags = 0; flags < 65536; ++flags) for (c = 0; c < 4; ++c) {
        unsigned selected = 0;
        for (i = 0; i < 16; ++i)
            if ((flags & (1u << i)) && standby_pmic_entries[i].control_reg == controls[c])
                selected |= (uint8_t)standby_pmic_entries[i].control_mask;
        for (b = 0; b < 4; ++b) {
            unsigned needs_write = (bytes[b] & selected) != (15u & ~selected);
            reset(bytes[b], controls[c]);
            if (standby_pmic_group_control(controls[c], flags) || bad ||
                calls != 1 + needs_write || writes != needs_write) return 3;
            if (written != (needs_write ? (bytes[b] & ~selected) : 0x100)) return 4;
        }
    }
    reset(0x5a, 0x80);
    if (standby_pmic_group_control(0x80, 0xffff0000) || calls != 2 || written != 0x5a || bad) return 5;
    reset(0xff, 0x80); read_error = -7;
    if (standby_pmic_group_control(0x80, 0xffff) != -7 || calls != 1 || writes || bad) return 6;
    reset(0xff, 0x80); write_error = -19;
    if (standby_pmic_group_control(0x80, 0xffff) != -19 || calls != 2 || written != 0xe0 || bad) return 7;
    reset(0xab, 3); expected_address = 0x1234;
    if (standby_pmic_read_id(expected_address, &value) || calls != 1 || writes || value != 0xab || bad) return 8;
    reset(0xcd, 3); expected_address = 0x134; read_error = -7;
    if (standby_pmic_read_id(expected_address, &value) != -7 || calls != 1 || value != 0xcd || bad) return 9;
    for (i = 0; i < 5; ++i) {
        uint32_t slot[] = {0xfeedface, 0, 0xcafef00d};
        init_slot = &slot[1]; init_value = 0x12345634;
        init_index = i; init_error = -13; init_calls = init_bad = 0;
        if (standby_pmic_initialize(init_slot, init_value, i) || init_calls != 1 || init_bad ||
            slot[1] != init_value || slot[0] != 0xfeedface || slot[2] != 0xcafef00d) return 10;
    }
    return 0;
}
