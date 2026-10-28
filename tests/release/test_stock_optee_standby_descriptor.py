"""Verify the recovered descriptor selector's complete bytes and ARM behavior."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'vendor/optee/standby-src/descriptor.S'
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class StandbyDescriptorTests(unittest.TestCase):
    def test_complete_body_and_selection_edges(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            subprocess.run([CROSS + 'gcc', '-c', '-marm', '-march=armv7-a', SOURCE,
                            '-o', out / 'descriptor.o'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.standby_find_descriptor',
                            out / 'descriptor.o', out / 'descriptor.bin'], check=True)
            body = (out / 'descriptor.bin').read_bytes()
            self.assertEqual(len(body), 88)
            self.assertEqual(hashlib.sha256(body).hexdigest(),
                             'c2ccd9a776d6e8f8c467636e496ff1fd918cf46bcf6df6b78421151779e444ac')
            self.assertIn('There are no relocations', subprocess.check_output(
                [CROSS + 'readelf', '-rW', out / 'descriptor.o'], text=True))
            self.assertFalse(subprocess.check_output([CROSS + 'nm', '-u', out / 'descriptor.o']).strip())
            (out / 'test.c').write_text(r'''
#include <stdint.h>
extern uint32_t standby_find_descriptor(const uint32_t *, uint32_t);
static int check(uint32_t count, uint32_t flags, uint32_t expected) {
    const uint32_t descriptor[] = {0, 0, count, 0x10000000};
    return standby_find_descriptor(descriptor, flags) != expected;
}
int main(void) {
    unsigned count, bit;
    for (count = 0; count <= 33; ++count) {
        if (check(count, 0, 0)) return 1;
        if (check(count, 1, 0x10000000)) return 2;
        for (bit = 1; bit < 32; ++bit) {
            unsigned flag = 1u << bit;
            unsigned expected = bit <= count ? 0x10000000 + 48 * bit : 0;
            if (check(count, flag, expected)) return 3;
            if (check(count, flag | 1, 0x10000000)) return 4;
        }
    }
    if (check(31, 0x80000088, 0x10000000 + 48 * 3)) return 5;
    if (check(255, 0, 0)) return 6;
    /* ARM register shifts use the low byte of the shift count. */
    if (check(256, 0, 0)) return 7;
    return 0;
}
__asm__(".text\n.arm\n.global _start\n_start:\nbl main\nmov r7,#1\nsvc #0\n");
''')
            subprocess.run([CROSS + 'gcc', '-nostdlib', '-static', '-marm', '-march=armv7-a',
                            '-O2', '-fno-builtin', '-Wl,-e,_start', out / 'test.c',
                            out / 'descriptor.o', '-o', out / 'test'], check=True)
            subprocess.run(['qemu-arm', out / 'test'], check=True, timeout=10)


if __name__ == '__main__':
    unittest.main()
