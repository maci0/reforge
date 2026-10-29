/* Private RTC/GIC banks and explicit service models; no physical suspend. */
#define _GNU_SOURCE
#include <stdint.h>
#include <signal.h>
#include <stdarg.h>
#include <string.h>
#include <setjmp.h>
#include <ucontext.h>
#include <unistd.h>
extern int psci_cpu_suspend(uint32_t, uintptr_t, uint32_t, void *);
static volatile uint32_t rtc[256], gic[4];
uintptr_t rtc_base = (uintptr_t)rtc;
unsigned char tee_spare_head[4];
static uint32_t before[256], gic_before[4], nsec[33];
static uint32_t core, state, level, entry, context;
static volatile unsigned stage;
static sigjmp_buf escape;
static void require(int value) { if (!value) _exit(90); }
static void check_rtc(unsigned phase) {
    unsigned i;
    for (i=0;i<256;++i) {
        uint32_t expected = before[i];
        if (phase && core == 0 && level <= 1 && i == 0x1c0/4) expected = 0xfa50392f;
        if (phase >= 2 && i == 0x71+core) expected = (uintptr_t)tee_spare_head;
        if (phase >= 3 && i == 0xb8+core) expected |= level < 2 ? 1u << (level*16) : 0;
        require(rtc[i] == expected);
    }
}
unsigned standby_cpu_get_core(void) { require(stage == 0); stage=1; return core; }
void trace_printf(const char *name, int line, int priority, int prefix, const char *format, ...) {
    va_list args;
    require(!strcmp(name,"psci_cpu_suspend") && priority == 3 && prefix == 1);
    check_rtc(0); va_start(args,format);
    if (stage == 1) {
        require(line == 158 && !strcmp(format,"core%d affinity_level=%d\n"));
        require(va_arg(args,unsigned) == core && va_arg(args,unsigned) == level); stage=2;
    } else {
        require(stage == 2 && line == 165 && !strcmp(format,"cpu_resume:0x%x\n"));
        require(va_arg(args,unsigned) == entry); stage=3;
    }
    va_end(args);
}
void generic_boot_set_core_ns_entry(unsigned cpu, uintptr_t address, uint32_t id) {
    require(stage == 3 && cpu == core && address == entry && id == context); check_rtc(1); stage=4;
}
void *phys_to_virt_io(uint32_t physical) {
    require(stage == 4 && physical == 0x03022000); check_rtc(2); stage=5; return (void *)gic;
}
void psci_armv7_cpu_off(void) {
    unsigned i;
    require(stage == 5); check_rtc(2);
    for (i=0;i<4;++i) require(gic[i] == (i==0 ? (gic_before[i]&~3u)|0x1e0 : gic_before[i]));
    stage=6;
}
unsigned thread_mask_exceptions(unsigned mask) { require(stage == 6 && mask == 7); stage=7; return 2; }
static void stop_wait(int signal, siginfo_t *info, void *context_pointer) {
    ucontext_t *uc = context_pointer;
    uintptr_t base=(uintptr_t)psci_cpu_suspend & ~1u, pc=uc->uc_mcontext.arm_pc & ~1u;
    unsigned i;
    (void)info;
    require(stage == 7 && (signal == SIGILL || signal == SIGALRM));
    require(pc == base+0xa0 || (signal == SIGALRM && pc == base+0xa2));
    check_rtc(3);
    for (i=0;i<33;++i) require(nsec[i] == (0x76540000u+i));
    stage=8; alarm(0); siglongjmp(escape,1);
}
static void setup(uint32_t power, unsigned cpu) {
    unsigned i;
    state=power; core=cpu; level=(state>>24)&3; entry=0x45670001+cpu*4; context=0xc0ffee00+cpu;
    stage=0;
    for (i=0;i<256;++i) rtc[i]=before[i]=0x5aa55aa5 ^ (i*0x01010101);
    for (i=0;i<4;++i) gic[i]=gic_before[i]=0xa55aa55a ^ i;
    for (i=0;i<33;++i) nsec[i]=0x76540000+i;
}
int main(void) {
    const uint32_t invalid[]={1,0xff,0xffff,0x80000001,0xffffffff};
    struct sigaction action={0}; volatile unsigned c,l; unsigned i;
    for (c=0;c<2;++c) for (i=0;i<5;++i) {
        setup(invalid[i],c); require(psci_cpu_suspend(state,entry,context,nsec) == -2 && stage == 3); check_rtc(0);
        require(!memcmp((const void *)gic,gic_before,sizeof(gic_before)));
    }
    action.sa_sigaction=stop_wait; action.sa_flags=SA_SIGINFO;
    require(sigaction(SIGILL,&action,0)==0 && sigaction(SIGALRM,&action,0)==0);
    for (c=0;c<2;++c) for (l=0;l<4;++l) {
        setup(0xa0000000u | (l<<24) | ((l&1)<<16),c);
        if (!sigsetjmp(escape,1)) { alarm(1); psci_cpu_suspend(state,entry,context,nsec); _exit(91); }
        require(stage == 8);
    }
    return 0;
}
