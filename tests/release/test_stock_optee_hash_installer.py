"""Exercise the recovered hash installer with controlled boot data under ARM QEMU."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
PATCH = ROOT / 'vendor/optee/stock-patches/0005-source-hash-installer.patch'


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class HashInstallerTests(unittest.TestCase):
    def test_copy_count_logging_and_allocation_failure(self):
        text = PATCH.read_text().split('+++ b/core/arch/arm/plat-sun8iw20p1/hash_install_asm.S\n', 1)[1]
        text = text.split('\n--- ', 1)[0]
        assembly = '\n'.join(line[1:] for line in text.splitlines() if line.startswith('+')) + '\n'
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            (out / 'installer.S').write_text(assembly)
            (out / 'test.c').write_text(r'''
#include <stdarg.h>
struct entry { char name[16]; unsigned char digest[32]; };
struct header { unsigned char prefix[0xc0c]; int count; struct entry entries[16]; };
struct header tee_spare_head;
struct entry *sunxi_hash_list;
int sunxi_hash_count;
static struct entry buffer[2];
static unsigned allocated;
static int fail_allocation, log_count, error;
extern void sunxi_hash_install(void);
void *malloc(unsigned size) { allocated = size; return fail_allocation ? 0 : buffer; }
void *memcpy(void *dst, const void *src, unsigned n) {
    unsigned char *d = dst; const unsigned char *s = src; unsigned i;
    for (i = 0; i < n; ++i) d[i] = s[i];
    return dst;
}
static int equal_string(const char *a, const char *b) {
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}
void trace_printf(const char *name, int line, int level, int prefix, const char *format, ...) {
    va_list args;
    if (!equal_string(name, "sunxi_hash_install") || prefix != 1) error = 1;
    if (fail_allocation) {
        if (line != 60 || level != 3 || !equal_string(format, "malloc failed\n")) error = 2;
    } else {
        const char *entry;
        va_start(args, format); entry = va_arg(args, const char *); va_end(args);
        if (line != 64 || level != 2 || !equal_string(format, "install hash %s\n") ||
            entry != tee_spare_head.entries[log_count].name) error = 3;
    }
    ++log_count;
}
/* The freestanding test never unwinds; OP-TEE supplies this personality in production. */
void __aeabi_unwind_cpp_pr0(void) {}
int main(void) {
    unsigned i;
    _Static_assert(__builtin_offsetof(struct header, count) == 0xc0c, "header ABI");
    tee_spare_head.count = 2;
    for (i = 0; i < 96; ++i) ((unsigned char *)tee_spare_head.entries)[i] = i + 7;
    sunxi_hash_count = 5;
    sunxi_hash_install();
    if (allocated != 96 || sunxi_hash_list != buffer || sunxi_hash_count != 7 || log_count != 2 || error) return 1;
    for (i = 0; i < 96; ++i)
        if (((unsigned char *)buffer)[i] != ((unsigned char *)tee_spare_head.entries)[i]) return 2;
    fail_allocation = 1;
    sunxi_hash_install();
    if (sunxi_hash_list || sunxi_hash_count != 7 || log_count != 3 || error) return 3;
    fail_allocation = 0;
    tee_spare_head.count = 0;
    sunxi_hash_install();
    return allocated || sunxi_hash_count != 7 || log_count != 3 || error;
}
__asm__(".text\n.arm\n.global _start\n_start:\nbl main\nmov r7,#1\nsvc #0\n");
''')
            subprocess.run([CROSS + 'gcc', '-c', '-mcpu=cortex-a7', '-mthumb',
                            out / 'installer.S', '-o', out / 'installer.o'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.sunxi_hash_install',
                            out / 'installer.o', out / 'installer.text'], check=True)
            code = bytearray((out / 'installer.text').read_bytes())
            self.assertEqual(len(code), 172)
            relocations = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'installer.o'], text=True)
            text_relocations = relocations.split("'.rel.text.sunxi_hash_install'", 1)[1].split('Relocation section', 1)[0]
            offsets = [int(value, 16) for value in re.findall(r'^([0-9a-f]{8})\s', text_relocations, re.M)]
            self.assertEqual(offsets, [0x14, 0x3a, 0x5e, 0x6c, 0x7c, 0x94, 0x98, 0x9c, 0xa0, 0xa4, 0xa8])
            for offset in offsets:
                code[offset:offset + 4] = b'\0' * 4
            # Digest of the independently extracted original function with only those relocations zeroed.
            self.assertEqual(hashlib.sha256(code).hexdigest(),
                             '30ddf17742bfb7aa213eafcb5264e0f1d37dabcf40841b53aaaccf6878b1fdcb')
            unwind = subprocess.check_output([CROSS + 'readelf', '--unwind', out / 'installer.o'], text=True)
            self.assertIn('0x8004afb0', unwind)
            subprocess.run([CROSS + 'gcc', '-nostdlib', '-static', '-marm', '-Os',
                            '-fno-builtin', '-Wl,-e,_start', out / 'test.c',
                            out / 'installer.o', '-o', out / 'test'], check=True)
            subprocess.run(['qemu-arm', out / 'test'], check=True)


if __name__ == '__main__':
    unittest.main()
