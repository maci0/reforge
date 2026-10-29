/* Test-only SRAM and service substitutes; no privileged helper or hardware runs. */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
extern void standby_host_suspend(void);
extern const unsigned char sunxi_standby_wrapper_start[], sunxi_standby_wrapper_end[];
uint32_t standby_host_settings[4];
uint32_t standby_host_configuration[52];
unsigned char tee_spare_head[172];
static unsigned char expected[240];
static unsigned stage, logs, copies, kind, failure;
static uint32_t word(const void *p) { uint32_t v; __builtin_memcpy(&v, p, 4); return v; }
static void put(unsigned off, uint32_t v) { __builtin_memcpy(expected + off, &v, 4); }
static void require(int condition) { if (!condition) _exit(90); }
void standby_host_resume_entry(void) { _exit(91); }
void standby_host_dcache_disable(void) { require(stage == 0); stage = 1; }
unsigned standby_host_get_type(void) { require(stage == 2); stage = 3; return kind; }
void standby_host_mmu_enable(void) { require(stage == 5); stage = 6; }
void standby_host_mmu_disable(void) { require(stage == 6); stage = 7; }
void *memcpy(void *dst, const void *src, unsigned n) {
    unsigned i;
    if ((uintptr_t)dst == 0x20000) {
        if (stage == 1) {
            require(src == sunxi_standby_wrapper_start && n == 16384); stage = 2;
        } else {
            require(stage == 3 && src == tee_spare_head + 44 && n == 128); stage = 4;
        }
        ++copies;
    }
    for (i = 0; i < n; ++i) ((unsigned char *)dst)[i] = ((const unsigned char *)src)[i];
    return dst;
}
void trace_printf(const char *name, int line, int level, int prefix, const char *format, ...) {
    static const unsigned offsets[] = {0x9c,0xa0,0xa4,0xa8,0xb0,0xac,0xc0,0xcc,0x94};
    static const char *formats[] = {"standby_type: 0x%8.8x\n", "vdd_cpua: 0x%8.8x\n",
        "vdd_cpub: 0x%8.8x\n", "vdd_sys: 0x%8.8x\n", "vcc_io: 0x%8.8x\n",
        "vdd_pll: 0x%8.8x\n", "pmu_port: 0x%8.8x\n", "pmu_addr: 0x%8.8x\n",
        "time_to_wakeup_ms: 0x%8.8x\n"};
    va_list args;
    require(level == 3 && prefix == 1 && logs < 12);
    va_start(args, format);
    if (logs < 9) {
        require(stage == 4 && !strcmp(name, "sram_init_para") && line == 151 + (int)logs);
        require(!strcmp(format, formats[logs]));
        /* pmu_addr is logged as one byte, even though the initializer copies words. */
        require(va_arg(args, unsigned) == (logs == 7 ? expected[0xcc] : word(expected + offsets[logs])));
    } else {
        require(!strcmp(name, "suspend2ram"));
        if (logs == 9) {
            require(stage == 4 && line == 179 && !strcmp(format,"enter standby, head size:0x%x\n"));
            require(va_arg(args, unsigned) == 240);
        } else if (logs == 10) {
            require(stage == 4 && line == 180 && !strcmp(format,"enter standby, SRAM_BASE:0x%x\n"));
            require(va_arg(args, unsigned) == 0x20000);
        } else require(stage == 7 && line == 186 && !strcmp(format,"exit standby\n"));
    }
    va_end(args);
    ++logs;
}
void test_sram_entry(void) {
    const unsigned char *sram = (const unsigned char *)0x20000;
    unsigned i;
    require(stage == 4 && logs == 11 && copies == 2);
    for (i = 0; i < 240; ++i) if (sram[i] != expected[i]) failure = 1;
    for (i = 240; i < 16384; ++i) if (sram[i] != sunxi_standby_wrapper_start[i]) failure = 2;
    stage = 5;
}
int main(void) {
    unsigned n, k, i;
    require(mmap((void *)0x20000,16384,PROT_READ|PROT_WRITE|PROT_EXEC,
                 MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED,-1,0) == (void *)0x20000);
    require(sunxi_standby_wrapper_end - sunxi_standby_wrapper_start == 16384);
    for (k = 1; k <= 2; ++k) for (n = 0; n <= 4; ++n) {
        for (i = 0; i < 172; ++i) tee_spare_head[i] = (i * 7 + n) & 255;
        for (i = 0; i < 52; ++i) standby_host_configuration[i] = 0x11223300 + i + n;
        for (i = 0; i < 4; ++i) standby_host_settings[i] = 0xaabbcc00 + i + n;
        standby_host_configuration[0xbc/4] = n;
        kind = k; stage = logs = copies = failure = 0;
        for (i = 0; i < 240; ++i) expected[i] = 0;
        for (i = 0; i < 128; ++i) expected[i] = tee_spare_head[i + 44];
        put(0x80, (uintptr_t)standby_host_resume_entry);
        put(0x84, standby_host_settings[1]); put(0x88, standby_host_settings[2]);
        put(0x94, standby_host_settings[3]); put(0x98, standby_host_settings[0] & 255);
        put(0x9c, kind);
        for (i = 0xa0; i <= 0xb0; i += 4) put(i, standby_host_configuration[i/4]);
        put(0xbc, n); put(0xc0, standby_host_configuration[0xc0/4]);
        put(0xc4, standby_host_configuration[0xc4/4]);
        for (i = 0; i < n; ++i) {
            expected[0xc8+i] = ((unsigned char *)standby_host_configuration)[0xc8+i];
            expected[0xcc+i] = ((unsigned char *)standby_host_configuration)[0xcc+i];
        }
        standby_host_suspend();
        require(stage == 7 && logs == 12 && copies == 2 && !failure);
    }
    return 0;
}
