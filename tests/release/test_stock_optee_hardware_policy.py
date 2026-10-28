"""Compare recovered policy instructions and execute original accept/reject behavior."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
PATCH = ROOT / 'vendor/optee/stock-patches/0007-source-hardware-policy.patch'


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class HardwarePolicyTests(unittest.TestCase):
    def test_instructions_unwind_and_original_policy(self):
        text = PATCH.read_text().split('+++ b/core/arch/arm/plat-sun8iw20p1/hardware_info_asm.S\n', 1)[1]
        text = text.split('\n--- ', 1)[0]
        assembly = '\n'.join(line[1:] for line in text.splitlines() if line.startswith('+')) + '\n'
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            (out / 'policy.S').write_text(assembly)
            (out / 'test.c').write_text(r'''
#include <stdint.h>
#include <stdarg.h>
struct header { uint8_t prefix[237], flags; uint16_t magic; uint8_t encoded[4]; };
struct header tee_spare_head;
static const uint8_t key[16] = {0x41,0x57,0x55,0xaa,1,2,3,4,4,3,2,1,0xa1,0xb1,0xa3,0xb3};
static unsigned hardware_id, copies, reads, logs, error, lines[2], decoded[4];
extern int check_hardware_info(void);
unsigned sunxi_get_hardware_id(void) { ++reads; return hardware_id; }
void *memcpy(void *dst, const void *src, unsigned n) {
    uint8_t *d = dst; const uint8_t *s = src; unsigned i;
    ++copies;
    if (n != 16) error = 1;
    for (i = 0; i < n; ++i) { if (s[i] != key[i]) error = 2; d[i] = s[i]; }
    return dst;
}
static int equal_string(const char *a, const char *b) {
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}
void trace_printf(const char *name, int line, int level, int prefix, const char *format, ...) {
    va_list args; unsigned i;
    if (!equal_string(name, "check_hardware_info") || prefix != 1 || logs == 2) error = 3;
    if (logs < 2) lines[logs] = line;
    ++logs;
    if (level != ((line == 110 || line == 117) ? 3 : 1)) error = 4;
    switch (line) {
    case 90: if (!equal_string(format, "hardware check error1\n")) error = 5; break;
    case 95: if (!equal_string(format, "hardware check error2\n")) error = 6; break;
    case 110: case 117: if (!equal_string(format, "check OK\n")) error = 7; break;
    case 122:
        if (!equal_string(format, "data: %x %x %x %x\n")) error = 8;
        va_start(args, format);
        for (i = 0; i < 4; ++i) if (va_arg(args, unsigned) != decoded[i]) error = 9;
        va_end(args); break;
    case 123: if (!equal_string(format, "hardware error 3\n")) error = 10; break;
    default: error = 11;
    }
}
static void setup(unsigned id, unsigned count, unsigned a, unsigned b, unsigned c, unsigned d) {
    unsigned i, mask = 0;
    hardware_id = id;
    copies = reads = logs = error = 0;
    decoded[0] = a; decoded[1] = b; decoded[2] = c; decoded[3] = d;
    for (i = 0; i < 16; ++i) mask ^= key[i];
    for (i = 0; i < 4; ++i) {
        tee_spare_head.encoded[i] = decoded[i] ^ mask;
        if (i >= count) decoded[i] = 0;
    }
    tee_spare_head.flags = 0x50 | count;
    tee_spare_head.magic = 0x5741;
}
static int run(unsigned expected, unsigned line1, unsigned line2) {
    uint8_t snapshot[sizeof(tee_spare_head)]; unsigned i;
    /* Keep a snapshot without invoking the key-copy instrumentation. */
    for (i = 0; i < sizeof(snapshot); ++i) snapshot[i] = ((uint8_t *)&tee_spare_head)[i];
    if (check_hardware_info() != expected || copies != 1 || reads != 1 || error) return 1;
    if (logs != (!!line1 + !!line2) || (line1 && lines[0] != line1) || (line2 && lines[1] != line2)) return 2;
    for (i = 0; i < sizeof(snapshot); ++i) if (snapshot[i] != ((uint8_t *)&tee_spare_head)[i]) return 3;
    return 0;
}
int main(void) {
    _Static_assert(__builtin_offsetof(struct header, flags) == 237, "flags ABI");
    _Static_assert(__builtin_offsetof(struct header, magic) == 238, "magic ABI");
    _Static_assert(__builtin_offsetof(struct header, encoded) == 240, "ID ABI");
    setup(0, 5, 0,0,0,0); tee_spare_head.magic = 0; if (run(0,0,0)) return 1;
    setup(0x10000, 5, 0,0,0,0); tee_spare_head.magic = 0; if (run(0,0,0)) return 2;
    setup(0x12, 1, 0x12,0,0,0); tee_spare_head.magic = 0; if (run(1,90,0)) return 3;
    setup(0x12, 5, 0x12,0,0,0); if (run(1,90,0)) return 4;
    setup(0x12, 1, 0x12,0,0,0); tee_spare_head.flags = 0x41; if (run(2,95,0)) return 5;
    setup(0x12, 1, 0x12,0,0,0); if (run(0,117,0)) return 6;
    setup(0x45, 4, 0x12,0x23,0x34,0x45); if (run(0,117,0)) return 7;
    setup(0x56, 4, 0x12,0x23,0x34,0x45); if (run(3,122,123)) return 8;
    setup(0x1234, 2, 0x12,0x34,0,0); if (run(0,110,0)) return 9;
    setup(0x3456, 4, 0x12,0x23,0x34,0x56); if (run(0,110,0)) return 10;
    setup(0x3456, 2, 0x34,0x12,0x56,0); if (run(3,122,123)) return 11;
    setup(0x1200, 1, 0x12,0x34,0,0); if (run(0,110,0)) return 12;
    setup(0x1234, 1, 0x12,0x34,0,0); if (run(3,122,123)) return 13;
    setup(0x1200, 3, 0x56,0x78,0x12,0xff); if (run(0,110,0)) return 14;
    setup(0x12, 0, 0x12,0,0,0); if (run(3,122,123)) return 15;
    return 0;
}
__asm__(".text\n.arm\n.global _start\n_start:\nbl main\nmov r7,#1\nsvc #0\n");
''')
            subprocess.run([CROSS + 'gcc', '-c', '-mcpu=cortex-a7', '-mthumb',
                            out / 'policy.S', '-o', out / 'policy.o'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.check_hardware_info',
                            out / 'policy.o', out / 'policy.text'], check=True)
            code = bytearray((out / 'policy.text').read_bytes())
            self.assertEqual(len(code), 336)
            rel = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'policy.o'], text=True)
            rel = rel.split("'.rel.text.check_hardware_info'", 1)[1].split('Relocation section', 1)[0]
            offsets = [int(value, 16) for value in re.findall(r'^([0-9a-f]{8})\s', rel, re.M)]
            self.assertEqual(offsets, [0x14,0x20,0x48,0x6a,0xe2,0x10e,0x11e,0x130,0x134,0x138,0x13c,0x140,0x144,0x148,0x14c])
            for offset in offsets:
                code[offset:offset + 4] = b'\0' * 4
            self.assertEqual(hashlib.sha256(code).hexdigest(),
                             'b9de6d6f32762b949a768f2915d97b7a5864b5faff8851ebaac40f9c65e9b5de')
            unwind = subprocess.check_output([CROSS + 'readelf', '--unwind', out / 'policy.o'], text=True)
            self.assertIn('[cantunwind]', unwind)
            subprocess.run([CROSS + 'gcc', '-nostdlib', '-static', '-marm', '-Os', '-fno-builtin',
                            '-Wl,-e,_start', out / 'test.c', out / 'policy.o', '-o', out / 'test'], check=True)
            subprocess.run(['qemu-arm', out / 'test'], check=True)


if __name__ == '__main__':
    unittest.main()
