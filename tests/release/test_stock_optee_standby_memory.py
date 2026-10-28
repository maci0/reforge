"""Verify recovered SRAM memory helpers and run them against guest-only memory."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
SOURCE = ROOT / 'vendor/optee/standby-src/memory.c'
FLAGS = ['-O2', '-marm', '-march=armv7-a', '-mtune=cortex-a9', '-ffreestanding',
         '-fno-builtin', '-fno-unwind-tables', '-ffunction-sections']


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class StandbyMemoryTests(unittest.TestCase):
    def test_original_bytes_master_masks_and_checksum_edges(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            subprocess.run([CROSS + 'gcc', '-c', *FLAGS, SOURCE, '-o', out / 'memory.o'], check=True)
            expected = {
                'standby_dram_master_enable': (36, '7cb8f54e9c2a64a25b07b0751ebd98a3e1d8d8a06f70061dc86986ef9830957d'),
                'standby_dram_master_disable': (32, '025f90499410aa6694c042b28786db466ea64749073c171556b4f7d1c1be2c3a'),
                'standby_dram_checksum': (48, '702a4eff6b0ed85dee877a30d4c73cc6707251b9c1c92368e66c1e7e3f4be267'),
            }
            for name, (length, digest) in expected.items():
                path = out / (name + '.text')
                subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.' + name,
                                out / 'memory.o', path], check=True)
                self.assertEqual(path.stat().st_size, length)
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest)
            (out / 'test.c').write_text(r'''
#include <stdint.h>
#include "memory.h"
static uint32_t data[4] = {0xffffffff, 2, 3, 4};
static uint32_t parameters[35];
static long map_test_bank(void) {
    register long a0 __asm__("r0") = 0x03102000;
    register long a1 __asm__("r1") = 4096;
    register long a2 __asm__("r2") = 3;
    register long a3 __asm__("r3") = 0x32;
    register long a4 __asm__("r4") = -1;
    register long a5 __asm__("r5") = 0;
    register long number __asm__("r7") = 192;
    /* Linux ARM mmap2: anonymous private fixed mapping inside this QEMU guest. */
    __asm__ volatile("svc #0" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a3),
                     "r"(a4), "r"(a5), "r"(number) : "memory", "cc");
    return a0;
}
static int bank_matches(unsigned enabled) {
    volatile uint32_t *bank = (volatile uint32_t *)0x03102000;
    unsigned i;
    for (i = 0; i < 1024; ++i) {
        uint32_t expected = 0xa5a50000 + i;
        if (i == 8) expected = enabled ? 0xffffffff : 1;
        if (i == 9) expected = enabled ? 0xff : 0;
        if (i == 10) expected = enabled ? 0xffff : 0;
        if (bank[i] != expected) return 0;
    }
    return 1;
}
int main(void) {
    volatile uint32_t *bank = (volatile uint32_t *)0x03102000;
    unsigned i;
    if (map_test_bank() != 0x03102000) return 1;
    for (i = 0; i < 1024; ++i) bank[i] = 0xa5a50000 + i;
    standby_dram_master_enable(); if (!bank_matches(1)) return 2;
    standby_dram_master_disable(); if (!bank_matches(0)) return 3;
    standby_dram_master_enable(); if (!bank_matches(1)) return 4;
    parameters[33] = (uint32_t)(uintptr_t)data;
    parameters[34] = 0; if (standby_dram_checksum(parameters)) return 5;
    parameters[34] = 4; if (standby_dram_checksum(parameters) != 0xffffffff) return 6;
    parameters[34] = 16; if (standby_dram_checksum(parameters) != 8) return 7;
    parameters[34] = 3; if (standby_dram_checksum(parameters) != 0xffffffff) return 8;
    parameters[34] = 5; if (standby_dram_checksum(parameters) != 1) return 9;
    parameters[34] = 15; if (standby_dram_checksum(parameters) != 8) return 10;
    parameters[33] += 4; parameters[34] = 8;
    if (standby_dram_checksum(parameters) != 5) return 11;
    parameters[33] = 0xfffffff0; parameters[34] = 32;
    if (standby_dram_checksum(parameters)) return 12;
    if (!bank_matches(1)) return 13;
    return data[0] != 0xffffffff || data[1] != 2 || data[2] != 3 || data[3] != 4;
}
__asm__(".text\n.arm\n.global _start\n_start:\nbl main\nmov r7,#1\nsvc #0\n");
''')
            subprocess.run([CROSS + 'gcc', '-nostdlib', '-static', *FLAGS,
                            '-I' + str(SOURCE.parent), '-Wl,-e,_start', out / 'test.c',
                            out / 'memory.o', '-o', out / 'test'], check=True)
            subprocess.run(['qemu-arm', out / 'test'], check=True)


if __name__ == '__main__':
    unittest.main()
