/* Test-only peripheral: trap guest virtual MMIO; production code is unmodified. */
#define _GNU_SOURCE
#include <signal.h>
#include <stdint.h>
#include <sys/mman.h>
#include <ucontext.h>
#include <unistd.h>
#include "twi.h"
#include "pmic.h"

#define BASE 0x02502000u
#define LIMIT 0x4ffffu
static volatile uint32_t bank[5][9];
static volatile unsigned mode, phase, stops, bad, bad_phase, timeout_phase, stop_failure;
static volatile unsigned control_reads, status_reads, line_reads, sent_count, reset_writes;
static volatile uint32_t sent[8];
static volatile uint8_t received = 0xab;
static volatile unsigned active, status_high_bits, reset_pending, reset_reads;
static volatile unsigned polls[7];

static unsigned expected_status(unsigned step) {
    static const unsigned status[] = {0xf8, 8, 0x18, 0x28, 0x10, 0x40, 0x58};
    return step == 4 && mode == 1 ? 0x28 : status[step];
}
static uint32_t peripheral(unsigned controller, unsigned offset, int write, uint32_t value) {
    volatile uint32_t *r = bank[controller];
    unsigned index = offset / 4;
    if (index >= 9) _exit(90);
    if (write) {
        r[index] = value;
        if (offset == 0x18) {
            ++reset_writes;
            reset_pending = 3; /* Two busy reads before the reset-complete read. */
        } else if (active && offset == 0x08) {
            if (sent_count == 8) _exit(91);
            sent[sent_count++] = value;
        } else if (active && offset == 0x1c) {
            if (value) bad = 1;
            if (bad_phase == 0) r[4] = 0xee;
        } else if (active && offset == 0x0c) {
            if (value & 0x10) {
                phase = 0; ++stops;
                control_reads = status_reads = line_reads = 0;
                if (stop_failure != 1) r[3] &= ~0x10u;
                r[4] = stop_failure == 2 ? 0x1f8 : 0xf8;
                r[8] = stop_failure == 3 ? 0x13a : 0x3a;
            } else {
                ++phase;
                if (phase > 6) _exit(92);
                if (phase == 4) {
                    mode = value & 0x20 ? 0 : 1;
                    if (mode == 1) received = r[2];
                }
                r[3] = (value & ~0x20u) | 8;
                if (timeout_phase == phase) r[3] &= ~8u;
                r[4] = bad_phase == phase ? 0xee : expected_status(phase) | status_high_bits;
                if (phase == 6) r[2] = received;
            }
        }
        return value;
    }
    if (offset == 0x18) {
        ++reset_reads;
        if (reset_pending && !--reset_pending) r[index] &= ~1u;
    }
    if (active && offset == 0x0c) ++polls[phase];
    if (active && phase == 0) {
        if (offset == 0x0c) ++control_reads;
        if (offset == 0x10) ++status_reads;
        if (offset == 0x20) ++line_reads;
    }
    return r[index];
}
static void fault(int signal, siginfo_t *info, void *context) {
    ucontext_t *u = context;
    unsigned long *regs = &u->uc_mcontext.arm_r0;
    uint32_t instruction = *(uint32_t *)regs[15];
    unsigned base = (instruction >> 16) & 15, target = (instruction >> 12) & 15;
    unsigned address = regs[base], immediate = instruction & 0xfff;
    unsigned load = (instruction >> 20) & 1;
    /* Only unconditional, immediate-offset, preindexed ARM word LDR/STR. */
    if (signal != SIGSEGV || instruction >> 28 != 14 ||
        (instruction & 0x0f600000) != 0x05000000 || base == 15 || target == 15) _exit(93);
    address += instruction & (1u << 23) ? immediate : -immediate;
    if (address != (uintptr_t)info->si_addr || address < BASE || address >= BASE + 0x1400 || (address & 3)) _exit(94);
    if (load) regs[target] = peripheral((address - BASE) / 0x400, (address - BASE) % 0x400, 0, 0);
    else peripheral((address - BASE) / 0x400, (address - BASE) % 0x400, 1, regs[target]);
    regs[15] += 4;
}
static void reset(unsigned operation) {
    unsigned i, j;
    for (i = 0; i < 5; ++i) for (j = 0; j < 9; ++j) bank[i][j] = 0;
    mode = operation; phase = stops = bad = sent_count = reset_writes = 0;
    bad_phase = timeout_phase = ~0u; stop_failure = 0;
    control_reads = status_reads = line_reads = 0;
    active = 1; status_high_bits = reset_pending = reset_reads = 0; received = 0xab;
    for (i = 0; i < 7; ++i) polls[i] = 0;
    standby_twi_state.base = (void *)BASE;
    bank[0][3] = 0xc0;
    bank[0][4] = 0xf8;
    bank[0][8] = 0x3a;
}
static int transaction(unsigned operation, unsigned fail_status, unsigned fail_timeout, unsigned expected) {
    uint8_t value = 0x56;
    unsigned read = operation != 1;
    int result;
    reset(operation); bad_phase = fail_status; timeout_phase = fail_timeout;
    result = standby_twi_transfer(operation, 0x34, 0x82, &value);
    if ((unsigned)result != expected || stops != 2 || bad) return 1;
    if (!expected) {
        if (sent_count != 3 || sent[0] != 0x68 || sent[1] != 0x82) return 2;
        if (sent[2] != (read ? 0x69 : 0x56) || value != (read ? received : 0x56)) return 3;
    } else if (fail_status == 6 && value != received) return 4;
    else if (fail_status != 6 && value != 0x56) return 5;
    if (fail_timeout >= 1 && fail_timeout <= 6 && polls[fail_timeout] != LIMIT + 1) return 6;
    return 0;
}
int main(void) {
    struct sigaction action = {0};
    unsigned i, stage;
    uint8_t value;
    void *mapping = mmap((void *)BASE, 8192, PROT_NONE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (mapping != (void *)BASE) return 1;
    action.sa_sigaction = fault; action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGSEGV, &action, 0)) return 2;
    for (i = 0; i < 5; ++i) {
        reset(0); active = 0;
        bank[i][5] = 0x51 + i; bank[i][3] = 0xa7;
        if (standby_twi_init(i) || standby_twi_state.base != standby_twi_bases[i] ||
            standby_twi_state.divider != 0x51 + i || standby_twi_state.control != 0x80 ||
            bank[i][5] != 0x28 || reset_writes != 1 || reset_reads != 4) return 3;
        bank[i][5] = 0; standby_twi_set_divider();
        if (bank[i][5] != 0x28) return 4;
        bank[i][3] = 0x42;
        if (standby_twi_restore() || bank[i][5] != 0x51 + i || bank[i][3] != 0xc2 || reset_writes != 2 || !(bank[i][6] & 1)) return 5;
    }
    reset(0);
    if (standby_twi_stop() || stops != 1 || bank[0][3] != 0xc8) return 6;
    for (stage = 1; stage <= 3; ++stage) {
        reset(0); stop_failure = stage;
        if (standby_twi_stop() != -1 || stops != 1) return 7;
        if (stage == 1 && control_reads != LIMIT + 1) return 8;
        if (stage == 2 && status_reads != LIMIT) return 9;
        if (stage == 3 && line_reads != LIMIT) return 10;
    }
    if (transaction(0, ~0u, ~0u, 0) || transaction(1, ~0u, ~0u, 0) ||
        transaction(2, ~0u, ~0u, 0) || transaction(~0u, ~0u, ~0u, 0)) return 11;
    for (stage = 0; stage <= 6; ++stage)
        if (transaction(0, stage, ~0u, expected_status(stage))) return 12;
    if (transaction(1, 4, ~0u, 0x28)) return 13;
    for (stage = 1; stage <= 6; ++stage) {
        static const unsigned timeouts[] = {0, 0xff, 0xfe, 0xfd, 0xfb, 0xfa, 0xf9};
        if (transaction(0, ~0u, stage, timeouts[stage])) return 14;
    }
    if (transaction(1, ~0u, 4, 0xfc)) return 15;
    /* Run the actual PMIC wrappers through the source-built TWI engine. */
    reset(0); value = 0;
    if (standby_pmic_read((const uint8_t *)"\x34", 0x82, &value) || value != received || sent[0] != 0x68) return 16;
    reset(1); value = 0x5a;
    if (standby_pmic_write((const uint8_t *)"\x34", 0x82, &value) || sent[2] != 0x5a) return 17;
    reset(0); status_high_bits = 0x10000; value = 0;
    if (standby_twi_transfer(0, 0x134, 0x12345682, &value) || value != received ||
        sent[0] != 0x68 || sent[1] != 0x12345682 || sent[2] != 0x269) return 18;
    reset(0);
    if (standby_pmic_update((const uint8_t *)"\x34", 0x82, 5, 15) ||
        received != 0xa5 || stops != 4 || sent_count != 6 || sent[5] != 0xa5) return 19;
    reset(0);
    if (standby_pmic_update((const uint8_t *)"\x34", 0x82, 11, 15) ||
        received != 0xab || stops != 2 || sent_count != 3) return 20;
    reset(0); stop_failure = 3; value = 0;
    if (standby_twi_transfer(0, 0x34, 0x82, &value) || value != received || stops != 2) return 21;
    return 0;
}
