/* Test-only register banks and service models; no hardware addresses are mapped. */
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
extern int psci_cpu_on(uint32_t, uint32_t, uint32_t);
extern int psci_affinity_info(uint32_t, uint32_t);
static volatile uint32_t control[33], entry_regs[128];
volatile uint32_t *cpucfg_base = control;
volatile uint32_t *rtc_base = entry_regs;
unsigned char tee_spare_head[4];
static uint32_t initial_control[33], initial_entry[128];
static uint32_t affinity, entry, context, current_core, exception_mask = 2;
static unsigned mode, stage, assert_logs;
static void require(int condition) { if (!condition) _exit(90); }
static void untouched(void) {
    unsigned i;
    for (i=0;i<33;++i) require(control[i] == initial_control[i]);
    for (i=0;i<128;++i) require(entry_regs[i] == initial_entry[i]);
}
static void setup(void) {
    unsigned i;
    for (i=0;i<33;++i) control[i] = initial_control[i] = 0xa5a55a5a ^ (i*0x01010101);
    for (i=0;i<128;++i) entry_regs[i] = initial_entry[i] = 0x12345678 ^ i;
    stage = 0;
}
unsigned thread_get_exceptions(void) { return exception_mask; }
unsigned __get_core_pos(void) { return current_core; }
void _assert_log(const char *expr, const char *file, int line, const char *name) {
    require(exception_mask == 0 && line == 22 && !strcmp(name,"get_core_pos"));
    require(!strcmp(expr,"thread_get_exceptions() & THREAD_EXCP_FOREIGN_INTR"));
    require(!strcmp(file,"core/arch/arm/include/kernel/misc.h"));
    ++assert_logs;
}
void _assert_break(void) { require(assert_logs == 1); _exit(42); }
void trace_printf(const char *name, int line, int level, int prefix, const char *format, ...) {
    va_list args;
    require(stage == 0 && level == 3 && prefix == 1);
    untouched();
    va_start(args,format);
    if (mode == 0) {
        require(!strcmp(name,"psci_cpu_on") && line == 227);
        require(!strcmp(format,"core_id: %d, entry 0x%x, context_id=0x%x"));
        require(va_arg(args,unsigned) == 1 && va_arg(args,unsigned) == entry && va_arg(args,unsigned) == context);
    } else {
        require(!strcmp(name,"psci_affinity_info") && line == 242);
        require(!strcmp(format,"core_id: %d, affinity %d"));
        require(va_arg(args,unsigned) == current_core && va_arg(args,unsigned) == affinity);
    }
    va_end(args);
    stage = 1;
}
void generic_boot_set_core_ns_entry(unsigned core, uintptr_t target, unsigned id) {
    require(mode == 0 && stage == 1 && core == 1 && target == entry && id == context);
    untouched(); stage = 2;
}
void udelay(unsigned delay) {
    unsigned i;
    require(mode == 0 && stage == 2 && delay == 20);
    for (i=0;i<33;++i) require(control[i] == ((i==0 || i==4) ? initial_control[i] & ~2u : initial_control[i]));
    for (i=0;i<128;++i) require(entry_regs[i] == (i==0x1c8/4 ? (uintptr_t)tee_spare_head : initial_entry[i]));
    stage = 3;
}
static uint32_t arm_one_shift(uint32_t amount) {
    amount &= 255;
    return amount >= 32 ? 0 : 1u << amount;
}
int main(void) {
    const uint32_t prefixes[] = {0,0x100,0x80000000,0xffffff00};
    const uint32_t status[] = {0,0xffffffff,0x00030000,0xa5a55a5a};
    const uint32_t edges[] = {0x100,0x10001,0x80000001,0xffffffff,0xfffffff0,0xfffffff1};
    const uint32_t levels[] = {0,1,0xffffffff};
    unsigned p, low, i, s, a, level;
    int result;
    mode = 0;
    for (p=0;p<4;++p) for (low=0;low<256;++low) {
        uint32_t cpu = prefixes[p] | low;
        setup(); entry = 0x45670001 + low*4; context = 0xdead0000 + p*256 + low;
        result = psci_cpu_on(cpu,entry,context);
        if (low != 1) { require(result == -2 && stage == 0); untouched(); continue; }
        require(result == 0 && stage == 3);
        for (i=0;i<33;++i) {
            uint32_t expected = initial_control[i];
            if (i == 0) expected |= 2;
            if (i == 4) expected &= ~2u;
            require(control[i] == expected);
        }
        for (i=0;i<128;++i) require(entry_regs[i] == (i==0x1c8/4 ? (uintptr_t)tee_spare_head : initial_entry[i]));
    }
    mode = 1;
    for (current_core=0;current_core<2;++current_core) for (s=0;s<4;++s)
    for (a=0;a<262;++a) for (level=0;level<3;++level) {
        uint32_t expected;
        setup(); affinity = a < 256 ? a : edges[a-256];
        control[32] = initial_control[32] = status[s];
        result = psci_affinity_info(affinity,levels[level]);
        expected = (status[s] & arm_one_shift(affinity + 16)) != 0;
        require(result == (int)expected && stage == 1);
        for (i=0;i<33;++i) require(control[i] == (i==0 && expected ? initial_control[i] & ~arm_one_shift(affinity) : initial_control[i]));
        for (i=0;i<128;++i) require(entry_regs[i] == initial_entry[i]);
    }
    {
        pid_t child; int status_code;
        exception_mask = 0; assert_logs = 0;
        child = fork(); require(child >= 0);
        if (!child) { psci_affinity_info(0,0); _exit(91); }
        require(waitpid(child,&status_code,0) == child && WIFEXITED(status_code) && WEXITSTATUS(status_code) == 42);
    }
    return 0;
}
