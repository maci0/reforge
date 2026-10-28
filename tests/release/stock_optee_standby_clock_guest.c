/* Test-only virtual MMIO and ordered trace; real clock and delay objects execute. */
#define _GNU_SOURCE
#include <signal.h>
#include <stdint.h>
#include <sys/mman.h>
#include <ucontext.h>
#include <unistd.h>
#include "clock.h"

#define CCU 0x02001000u
#define PRCM 0x07010000u
struct access { unsigned address, write, value; };
static volatile uint32_t bank[2][1024];
static uint32_t model[2][1024];
static volatile struct access observed[128];
static struct access expected[128];
static volatile unsigned count;
static unsigned expected_count;
static unsigned bank_index(unsigned address) {
    if (address >= CCU && address < CCU + 4096) return 0;
    if (address >= PRCM && address < PRCM + 4096) return 1;
    _exit(90);
}
static unsigned word_index(unsigned address) {
    unsigned base = bank_index(address) ? PRCM : CCU;
    if (address & 3) _exit(91);
    return (address - base) / 4;
}
static void fault(int signal, siginfo_t *info, void *context) {
    ucontext_t *u = context;
    unsigned long *regs = &u->uc_mcontext.arm_r0;
    uint32_t instruction = *(uint32_t *)regs[15];
    unsigned base = (instruction >> 16) & 15, target = (instruction >> 12) & 15;
    unsigned address = regs[base], immediate = instruction & 0xfff;
    unsigned load = (instruction >> 20) & 1, value, b, i;
    if (signal != SIGSEGV || instruction >> 28 != 14 ||
        (instruction & 0x0f600000) != 0x05000000 || base == 15 || target == 15) _exit(92);
    address += instruction & (1u << 23) ? immediate : -immediate;
    if (address != (uintptr_t)info->si_addr || count == 128) _exit(93);
    b = bank_index(address); i = word_index(address);
    if (load) { value = bank[b][i]; regs[target] = value; }
    else { value = regs[target]; bank[b][i] = value; }
    observed[count].address = address;
    observed[count].write = !load;
    observed[count].value = value;
    ++count; regs[15] += 4;
}
static unsigned read_expected(unsigned address) {
    unsigned value = model[bank_index(address)][word_index(address)];
    if (expected_count == 128) _exit(94);
    expected[expected_count++] = (struct access){address, 0, value};
    return value;
}
static void write_expected(unsigned address, unsigned value) {
    if (expected_count == 128) _exit(95);
    model[bank_index(address)][word_index(address)] = value;
    expected[expected_count++] = (struct access){address, 1, value};
}
static void select_expected(unsigned mode) {
    unsigned i, bits = (mode << 31) | (mode << 30) | (mode << 29);
    for (i = 0; i < 8; ++i) {
        unsigned address = standby_clock_registers[i];
        write_expected(address, (read_expected(address) & 0x1fffffff) | bits);
    }
}
static void seed(unsigned value) {
    unsigned b, i;
    for (b = 0; b < 2; ++b) for (i = 0; i < 1024; ++i) {
        value = value * 1664525u + 1013904223u;
        bank[b][i] = model[b][i] = value;
    }
    count = expected_count = 0;
}
static int matches(void) {
    unsigned b, i;
    if (count != expected_count) return 1;
    for (i = 0; i < count; ++i)
        if (observed[i].address != expected[i].address || observed[i].write != expected[i].write ||
            observed[i].value != expected[i].value) return 2;
    for (b = 0; b < 2; ++b) for (i = 0; i < 1024; ++i)
        if (bank[b][i] != model[b][i]) return 3;
    return 0;
}
int main(void) {
    struct sigaction action = {0};
    static const unsigned modes[] = {0, 1, 2, 3, 4, 7, 8, 15, 0xffffffff, 0x80000000};
    static const unsigned seeds[] = {1, 0xdeadbeef, 0xffffffff};
    unsigned trial, mode, i, pass, saved;
    struct standby_clock_context context[6];
    if (mmap((void *)CCU, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) != (void *)CCU ||
        mmap((void *)PRCM, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) != (void *)PRCM) return 1;
    action.sa_sigaction = fault; action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGSEGV, &action, 0)) return 2;
    for (trial = 0; trial < 3; ++trial) {
        for (mode = 0; mode < sizeof(modes) / sizeof(modes[0]); ++mode) {
            seed(seeds[trial]); select_expected(modes[mode]);
            standby_clock_select(modes[mode]);
            if (count != 16 || matches()) return 3;
        }
        for (i = 0; i < 6; ++i) {
            standby_clock_contexts[i].source = 0xa1;
            standby_clock_contexts[i].divider_n = 0xb2;
            standby_clock_contexts[i].divider_m = 0xc3;
            standby_clock_contexts[i].saved = i & 1 ? 0x80 : 0;
            context[i] = standby_clock_contexts[i];
        }
        for (pass = 0; pass < 2; ++pass) {
            seed(seeds[trial] + pass);
            for (i = 0; i < 6; ++i) {
                unsigned address = context[i].address, value = read_expected(address);
                if (!context[i].saved) {
                    context[i].source = (value >> 24) & 7;
                    context[i].divider_n = (value >> 8) & 3;
                    context[i].divider_m = value & 3;
                }
                context[i].saved = 1;
                write_expected(address, value & ~0x07000000u);
                write_expected(address, value & 0xf8fffc00u);
            }
            write_expected(CCU + 0x520, 0x01000000);
            saved = read_expected(CCU + 0xf38);
            write_expected(CCU + 0xf38, 0x80000000);
            write_expected(CCU + 0xf3c, (read_expected(CCU + 0xf3c) & ~0x38u) | 0x30);
            select_expected(0);
            {
                unsigned value = (read_expected(PRCM + 0x244) & ~1u) | 0xa7000000;
                write_expected(PRCM + 0x244, value); write_expected(PRCM + 0x244, value);
            }
            standby_clock_enter();
            if (count != 42 || matches() || standby_clock_saved_aux != saved) return 4;
            for (i = 0; i < 6; ++i)
                if (standby_clock_contexts[i].address != context[i].address ||
                    standby_clock_contexts[i].source != context[i].source ||
                    standby_clock_contexts[i].divider_n != context[i].divider_n ||
                    standby_clock_contexts[i].divider_m != context[i].divider_m ||
                    standby_clock_contexts[i].saved != 1) return 5;
        }
        count = expected_count = 0;
        {
            unsigned value = read_expected(PRCM + 0x244) | 0xa7000001;
            write_expected(PRCM + 0x244, value); write_expected(PRCM + 0x244, value);
        }
        select_expected(1);
        read_expected(CCU + 0x520); write_expected(CCU + 0x520, 0);
        write_expected(CCU + 0xf38, saved);
        write_expected(CCU + 0xf3c, (read_expected(CCU + 0xf3c) & ~0x38u) | 0x30);
        standby_clock_leave();
        if (count != 24 || matches()) return 6;
        for (i = 0; i < 6; ++i)
            if (standby_clock_contexts[i].source != context[i].source ||
                standby_clock_contexts[i].divider_n != context[i].divider_n ||
                standby_clock_contexts[i].divider_m != context[i].divider_m ||
                standby_clock_contexts[i].saved != 1) return 7;
    }
    return 0;
}
