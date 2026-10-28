/* Unmodified DRAM objects execute against test-only virtual word-MMIO banks. */
#define _GNU_SOURCE
#include <signal.h>
#include <stdint.h>
#include <sys/mman.h>
#include <ucontext.h>
#include <unistd.h>
#include "dram-state.h"

static const unsigned bases[] = {0x02001000, 0x03102000, 0x03103000, 0x07010000};
struct access { unsigned address, write, value; };
static volatile uint32_t bank[4][1024];
static uint32_t model[4][1024];
static volatile struct access seen[512];
static struct access expected[512];
static volatile unsigned count, actual_pending;
static unsigned expected_count, model_pending;
static unsigned locate(unsigned address) {
    unsigned i;
    for (i = 0; i < 4; ++i) if (address >= bases[i] && address < bases[i] + 4096) return i;
    _exit(90);
}
static unsigned access_bank(unsigned address, unsigned write, unsigned value, unsigned simulated) {
    unsigned b = locate(address), index = (address - bases[b]) / 4;
    volatile uint32_t *words = simulated ? model[b] : bank[b];
    unsigned pending = simulated ? model_pending : actual_pending;
    if (address & 3) _exit(91);
    if (write) {
        words[index] = value;
        if (address == 0x03103004) {
            pending = 3;
            words[0x18 / 4] &= ~7u;
        }
    } else {
        if (address == 0x03103018 && pending && !--pending) words[index] = (words[index] & ~7u) | 3;
        value = words[index];
    }
    if (simulated) {
        model_pending = pending;
        if (expected_count == 512) _exit(92);
        expected[expected_count++] = (struct access){address, write, value};
    } else {
        actual_pending = pending;
        if (count == 512) _exit(93);
        seen[count].address = address; seen[count].write = write; seen[count].value = value; ++count;
    }
    return value;
}
static unsigned rd(unsigned address) { return access_bank(address, 0, 0, 1); }
static void wr(unsigned address, unsigned value) { access_bank(address, 1, value, 1); }
static void fault(int signal, siginfo_t *info, void *context) {
    ucontext_t *u = context;
    unsigned long *r = &u->uc_mcontext.arm_r0;
    unsigned instruction = *(unsigned *)r[15];
    unsigned rn = (instruction >> 16) & 15, rt = (instruction >> 12) & 15;
    unsigned offset = instruction & 0xfff, address = r[rn], updated;
    unsigned load = (instruction >> 20) & 1, pre = (instruction >> 24) & 1;
    /* The fault proves the instruction condition passed. Support word SDT only. */
    if (signal != SIGSEGV || (instruction & 0x0c400000) != 0x04000000 || rn == 15 || rt == 15) _exit(94);
    if (instruction & (1u << 25)) {
        if ((instruction & 0xff0) != 0) _exit(95); /* Only the unshifted register offsets used here. */
        offset = r[instruction & 15];
    }
    updated = address + (instruction & (1u << 23) ? offset : -offset);
    if (pre) address = updated;
    if (address != (uintptr_t)info->si_addr) _exit(96);
    if (load) r[rt] = access_bank(address, 0, 0, 0);
    else access_bank(address, 1, r[rt], 0);
    if (!pre || (instruction & (1u << 21))) r[rn] = updated;
    r[15] += 4;
}
static void seed(unsigned value) {
    unsigned b, i;
    for (b = 0; b < 4; ++b) for (i = 0; i < 1024; ++i) {
        value = value * 1664525u + 1013904223u;
        bank[b][i] = model[b][i] = value;
    }
    count = expected_count = actual_pending = model_pending = 0;
}
static int matches(void) {
    unsigned b, i;
    if (count != expected_count) return 1;
    for (i = 0; i < count; ++i)
        if (seen[i].address != expected[i].address || seen[i].write != expected[i].write ||
            seen[i].value != expected[i].value) return 2;
    for (b = 0; b < 4; ++b) for (i = 0; i < 1024; ++i)
        if (bank[b][i] != model[b][i]) return 3;
    return 0;
}
int main(void) {
    static const unsigned first[] = {0x03102000, 0x03102004, 0x03103058, 0x0310305c,
        0x03103060, 0x03103064, 0x03103068, 0x0310306c, 0x03103078, 0x03103080,
        0x03103050, 0x03103054, 0x0310309c, 0x031030a0};
    static const unsigned masks[] = {0xf2063333, 0xe486cccc, 0xe9069999, 0xed866666,
                                     0xf2063333, 0xf5860000, 0xf2063333, 0xf2063333};
    struct sigaction action = {0};
    uint32_t saved[106], parameters[60] = {0};
    unsigned trial, i, lane, index, value, mode, flag, polls;
    for (i = 0; i < 4; ++i)
        if (mmap((void *)bases[i], 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) != (void *)bases[i]) return 1;
    action.sa_sigaction = fault; action.sa_flags = SA_SIGINFO; sigemptyset(&action.sa_mask);
    if (sigaction(SIGSEGV, &action, 0)) return 2;
    for (trial = 0; trial < 3; ++trial) {
        seed(0xdeadbeef + trial);
        for (i = 0; i < 106; ++i) saved[i] = standby_dram_state[i] = 0xfeed0000 + i;
        standby_saved_sp = 0xcafef00d;
        for (i = 0; i < 14; ++i) saved[i] = model[locate(first[i])][(first[i] & 0xfff) / 4];
        saved[14] = 0;
        for (lane = 0; lane < 4; ++lane) for (i = 0; i < 11; ++i)
            saved[15 + lane * 11 + i] = model[2][(0x310 + lane * 0x80 + i * 4) / 4];
        for (i = 0; i < 31; ++i) saved[60 + i] = model[2][(0x210 + i * 4) / 4];
        for (i = 0; i < 4; ++i) saved[95 + i] = model[2][(0x33c + i * 0x80) / 4];
        for (i = 0; i < 4; ++i) saved[100 + i] = model[1][(0x500 + i * 4) / 4];
        saved[104] = model[2][0x90 / 4]; saved[105] = model[2][0x94 / 4];
        /* Snapshot reads are intentionally interleaved; expected writes/state are checked below. */
        standby_dram_suspend();
        for (i = 0; i < 106; ++i) if (standby_dram_state[i] != saved[i]) return 3;
        if (standby_saved_sp != 0xcafef00d || actual_pending) return 4;
        /* Check all destructive writes, order and untouched neighbors independently of load scheduling. */
        index = polls = 0;
        for (i = 0; i < count; ++i) if (!seen[i].write) {
            if (seen[i].address == 0x03103018) {
                unsigned low = ++polls < 3 ? 0 : 3;
                if (seen[i].value != ((model[2][0x18 / 4] & ~7u) | low)) return 5;
            }
        } else {
            static const unsigned addresses[] = {0x03102020, 0x03102024, 0x03102028, 0x03103004,
                0x0310310c, 0x03103344, 0x031033c4, 0x03103208, 0x07010250, 0x0310300c,
                0x02001540, 0x0200180c, 0x0200180c, 0x02001010, 0x02001800, 0x02001800, 0x02001800};
            unsigned address = seen[i].address, b = locate(address), word = (address & 0xfff) / 4;
            if (index >= sizeof(addresses) / sizeof(addresses[0]) || address != addresses[index]) return 6;
            value = model[b][word];
            switch (index++) {
            case 0: value = 1; break;
            case 1: case 2: case 9: value = 0; break;
            case 3: value |= 0x101; model[2][0x18 / 4] = (model[2][0x18 / 4] & ~7u) | 3; break;
            case 4: value &= ~0xff0000u; break;
            case 5: case 6: value = (value & 0xff3f0ff2) | 0x0040500a; break;
            case 7: value = (value & ~0xc8u) | 0x313; break;
            case 8: value |= 3; break;
            case 10: case 14: value &= ~0x40000000u; break;
            case 11: value &= ~1u; break;
            case 12: value &= ~0x10000u; break;
            case 13: case 15: value &= ~0x80000000u; break;
            case 16: value |= 0x08000000; break;
            }
            if (seen[i].value != value) return 7;
            model[b][word] = value;
        }
        if (index != 17 || polls != 3 || count != 132) return 8;
        for (lane = 0; lane < 4; ++lane) for (i = 0; i < 1024; ++i) if (bank[lane][i] != model[lane][i]) return 9;
        seed(0x12345678 + trial);
        wr(0x03103100, rd(0x03103100) & ~0x04000000u);
        for (lane = 0; lane < 4; ++lane) for (i = 0; i < 11; ++i)
            wr(0x03103310 + lane * 0x80 + i * 4, saved[15 + lane * 11 + i]);
        for (i = 0; i < 31; ++i) wr(0x03103210 + i * 4, saved[60 + i]);
        for (i = 0; i < 4; ++i) wr(0x0310333c + i * 0x80, saved[95 + i]);
        wr(0x03103100, rd(0x03103100) | 0x04000000);
        standby_dram_restore_lanes(); if (matches() || count != 83) return 10;
        count = expected_count = 0;
        for (i = 0; i < 4; ++i) wr(0x03102500 + i * 4, saved[100 + i]);
        standby_dram_restore_common_config(); if (matches() || count != 4) return 11;
        for (mode = 0; mode < 8; ++mode) for (flag = 0; flag < 2; ++flag) {
            seed(0x87654321 + mode); bank[0][4] = model[0][4] = flag ? 2 : 0;
            parameters[23] = mode << 20;
            value = rd(0x02001010);
            if (value & 2) wr(0x02001014, rd(0x02001014) | 0x80000);
            wr(0x02001014, masks[mode]); wr(0x02001010, rd(0x02001010) | 0x01000000);
            if (standby_dram_configure_modulation(parameters, (void *)0x02001010, (void *)0x02001014) || matches()) return 12;
        }
        for (mode = 0; mode < 4; ++mode) {
            seed(0x1337 + mode); parameters[23] = ((mode & 1) << 16) | ((mode >> 1) << 17);
            parameters[15] = 0x12345678; parameters[16] = 0x87654321;
            if (!(mode & 2)) {
                wr(0x03103110, (rd(0x03103110) & 0x80808080) | parameters[15]);
                if (!(mode & 1)) wr(0x03103114, (rd(0x03103114) & ~0x7fu) | (parameters[16] & 0x7f));
            }
            standby_dram_configure_tpr5_6(parameters); if (matches()) return 13;
        }
    }
    return 0;
}
