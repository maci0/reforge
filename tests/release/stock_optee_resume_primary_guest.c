/* Execute the original Thumb sequence with explicit CP15 and service models. */
#define _GNU_SOURCE
#include <signal.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>
extern void generic_boot_resume_primary(void);
extern uint32_t standby_ns_resume_entry;
static unsigned stage, traps, logs;
static uint32_t initial_nsacr, modeled_nsacr;
static void require(int value) { if (!value) _exit(90); }
static void cp15_model(int signal, siginfo_t *info, void *context) {
    ucontext_t *uc = context;
    const uint16_t *instruction = (const uint16_t *)(uc->uc_mcontext.arm_pc & ~1u);
    (void)info;
    require(signal == SIGILL && stage == 4 && instruction[1] == 0x3f51);
    if (instruction[0] == 0xee11) {
        require(traps == 0);
        uc->uc_mcontext.arm_r3 = modeled_nsacr;
    } else {
        require(instruction[0] == 0xee01 && traps == 1);
        require(uc->uc_mcontext.arm_r3 == (initial_nsacr | 0xc00));
        modeled_nsacr = uc->uc_mcontext.arm_r3;
    }
    ++traps;
    uc->uc_mcontext.arm_pc += 4;
}
unsigned thread_set_exceptions(unsigned flags) { require(stage == 0 && flags == 7); stage = 1; return 0; }
void thread_init_per_cpu(void) { require(stage == 1); stage = 2; }
void init_sec_mon(unsigned address) { require(stage == 2 && address == standby_ns_resume_entry); stage = 3; }
void main_init_gic(void) { require(stage == 3); stage = 4; }
void trace_printf(const char *name, int line, int level, int prefix, const char *format, ...) {
    va_list args;
    require(stage == 4 && traps == 2 && modeled_nsacr == (initial_nsacr | 0xc00));
    require(!strcmp(name,"generic_boot_resume_primary") && line == 1248 && level == 3 && prefix == 1);
    require(!strcmp(format,"Primary CPU switching to normal world boot, cpu_resume:0x%x\n"));
    va_start(args, format); require(va_arg(args, unsigned) == standby_ns_resume_entry); va_end(args);
    ++logs; stage = 5;
}
int main(void) {
    struct sigaction action = {0};
    const uint32_t entries[] = {1, 0x40000000, 0x80000001, 0xdead0000};
    const uint32_t registers[] = {0, 0xffffffff, 0x80000000, 0x40000400};
    unsigned a, b;
    action.sa_sigaction = cp15_model; action.sa_flags = SA_SIGINFO;
    require(sigaction(SIGILL, &action, 0) == 0);
    for (a = 0; a < 4; ++a) for (b = 0; b < 4; ++b) {
        standby_ns_resume_entry = entries[a]; initial_nsacr = modeled_nsacr = registers[b];
        stage = traps = logs = 0;
        generic_boot_resume_primary();
        require(stage == 5 && traps == 2 && logs == 1 && standby_ns_resume_entry == entries[a]);
    }
    return 0;
}
