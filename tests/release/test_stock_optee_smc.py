"""Check the recovered SMC instructions and execute MMIO policy against a fake bank."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
PATCH = ROOT / 'vendor/optee/stock-patches/0006-source-smc-config.patch'


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class SmcTests(unittest.TestCase):
    def test_original_instructions_unwind_and_register_policy(self):
        text = PATCH.read_text().split('+++ b/core/arch/arm/plat-sun8iw20p1/smc_asm.S\n', 1)[1]
        text = text.split('\n--- ', 1)[0]
        assembly = '\n'.join(line[1:] for line in text.splitlines() if line.startswith('+')) + '\n'
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            (out / 'smc.S').write_text(assembly)
            (out / 'test.c').write_text(r'''
#include <stdint.h>
#include <stdarg.h>
extern int sunxi_smc_config(uint64_t start, uint64_t size);
static volatile uint32_t bank[16][4];
static uint32_t calls[128];
static unsigned ncalls, rounded, capacity, unavailable, error;
static uint64_t extra;
void *memset(void *p, int value, unsigned size) {
    unsigned char *b = p; unsigned i;
    for (i = 0; i < size; ++i) b[i] = value;
    return p;
}
void *phys_to_virt_io(uint32_t address) {
    if (address < 0x03007100 || address >= 0x03007200 || (address & 3) || ncalls == 128) {
        error = 1; return (void *)bank;
    }
    calls[ncalls++] = address;
    return (void *)((volatile uint32_t *)bank + (address - 0x03007100) / 4);
}
static int equal_string(const char *a, const char *b) {
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}
void trace_printf(const char *name, int line, int level, int prefix, const char *format, ...) {
    va_list args;
    if (level != 1 || prefix != 1) error = 2;
    if (line == 149) {
        ++unavailable;
        if (!equal_string(name, "sunxi_smc_config") ||
            !equal_string(format, "no available region for smc config!")) error = 3;
    } else {
        if (!equal_string(name, "generate_smc_mem_map")) error = 4;
        va_start(args, format); extra = va_arg(args, uint64_t); va_end(args);
        if (line == 106) {
            ++rounded;
            if (!equal_string(format, "TA RAM not SMC align, extra 0x%llx byte mem config secured!")) error = 5;
        } else if (line == 116) {
            ++capacity;
            if (!equal_string(format, "Not enough SMC region, 0x%llx byte ta ram left unsecured")) error = 6;
        } else error = 7;
    }
}
/* No unwinding is executed by this freestanding policy test. */
void __aeabi_unwind_cpp_pr0(void) {}
static void reset(void) {
    unsigned i;
    memset((void *)bank, 0, sizeof(bank));
    for (i = 0; i < 16; ++i) bank[i][3] = 0x5a5a5a5a;
    ncalls = rounded = capacity = unavailable = error = 0;
    extra = 0;
}
static int reserved_untouched(void) {
    unsigned i;
    for (i = 0; i < 16; ++i) if (bank[i][3] != 0x5a5a5a5a) return 0;
    return 1;
}
int main(void) {
    unsigned i;
    reset();
    if (sunxi_smc_config(0x41c00000, 0) || ncalls || error) return 1;
    reset();
    if (sunxi_smc_config(0x41c00000, 0x400000)) return 2;
    if (bank[0][0] != 0x01c00000 || bank[0][1] || bank[0][2] != 0xc000002b || ncalls != 4 || error) return 3;
    if (calls[0] != 0x03007108 || calls[1] != 0x03007104 || calls[2] != 0x03007100 || calls[3] != 0x03007108) return 4;
    if (!reserved_untouched()) return 5;
    reset();
    bank[0][0] = 0x11111111; bank[0][1] = 0x22222222; bank[0][2] = 0x33333333;
    sunxi_smc_config(0x40008000, 0x18000);
    if (bank[0][0] != 0x11111111 || bank[0][1] != 0x22222222 || bank[0][2] != 0x33333333) return 6;
    if (bank[1][0] != 0x8000 || bank[1][1] || bank[1][2] != 0xc000001d ||
        bank[2][0] != 0x10000 || bank[2][1] || bank[2][2] != 0xc000001f || ncalls != 8 || error) return 7;
    reset();
    sunxi_smc_config(0x140000000ULL, 0x10000);
    if (bank[0][0] || bank[0][1] != 1 || bank[0][2] != 0xc000001f || error) return 8;
    reset();
    sunxi_smc_config(0x41c00000, 1);
    if (rounded != 1 || extra != 32767 || bank[0][2] != 0xc000001d || error) return 9;
    reset();
    for (i = 0; i < 16; ++i) bank[i][2] = 1;
    sunxi_smc_config(0x41c00000, 0x400000);
    if (unavailable != 1 || ncalls != 16 || error || !reserved_untouched()) return 10;
    for (i = 0; i < 16; ++i) if (bank[i][0] || bank[i][1] || bank[i][2] != 1) return 11;
    reset();
    sunxi_smc_config(0x40000000, 17ULL << 32);
    if (capacity != 1 || extra != (9ULL << 30) || rounded || unavailable || error || ncalls != 49) return 12;
    if (!reserved_untouched()) return 13;
    for (i = 0; i < 16; ++i) if (!bank[i][2]) return 14;
    return 0;
}
__asm__(".text\n.arm\n.global _start\n_start:\nbl main\nmov r7,#1\nsvc #0\n");
''')
            subprocess.run([CROSS + 'gcc', '-c', '-mcpu=cortex-a7', '-mthumb',
                            out / 'smc.S', '-o', out / 'smc.o'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.sunxi_smc_config',
                            out / 'smc.o', out / 'smc.text'], check=True)
            code = bytearray((out / 'smc.text').read_bytes())
            self.assertEqual(len(code), 400)
            rel = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'smc.o'], text=True)
            rel = rel.split("'.rel.text.sunxi_smc_config'", 1)[1].split('Relocation section', 1)[0]
            offsets = [int(value, 16) for value in re.findall(r'^([0-9a-f]{8})\s', rel, re.M)]
            self.assertEqual(offsets, [0x1e, 0xa8, 0xb4, 0xd6, 0x104, 0x110, 0x118, 0x16c, 0x170, 0x174, 0x180, 0x184])
            for offset in offsets:
                code[offset:offset + 4] = b'\0' * 4
            self.assertEqual(hashlib.sha256(code).hexdigest(),
                             '9c8e8678ea82a8493afb395409ca65f95d3960109955b9fc966705575fc6096f')
            unwind = subprocess.check_output([CROSS + 'readelf', '--unwind', out / 'smc.o'], text=True)
            self.assertIn('0x80063faf', unwind)
            subprocess.run([CROSS + 'gcc', '-nostdlib', '-static', '-marm', '-Os', '-fno-builtin',
                            '-Wl,-e,_start', out / 'test.c', out / 'smc.o', '-o', out / 'test'], check=True)
            subprocess.run(['qemu-arm', out / 'test'], check=True)


if __name__ == '__main__':
    unittest.main()
