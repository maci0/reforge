"""Check recovered host helper bytes/relocations and execute the delay in user mode."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
SOURCE = ROOT / 'vendor/optee/standby-host-src/mmu.S'


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class HostMmuTests(unittest.TestCase):
    def test_instruction_bytes_calls_and_delay(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            subprocess.run([CROSS + 'gcc', '-c', SOURCE, '-o', out / 'mmu.o'], check=True)
            relocations = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'mmu.o'], text=True)
            for offset, target in [(0x1c, 'standby_host_delay'), (0x28, 'standby_host_delay'),
                                   (0x36, 'dcache_op_all'), (0x5c, 'dcache_op_all'),
                                   (0xa6, 'standby_host_delay'), (0xc2, 'standby_host_disable_sctlr_bits')]:
                self.assertIn(target, next(line for line in relocations.splitlines()
                                           if line.startswith(f'{offset:08x} ')))
            self.assertEqual(relocations.count('R_ARM_THM_'), 6)
            self.assertEqual(subprocess.check_output([CROSS + 'nm', '-u', out / 'mmu.o'], text=True).strip(),
                             'U dcache_op_all')
            # Synthetic test addresses verify genuine internal relocations independently of stock layout.
            subprocess.run([CROSS + 'ld', '-Ttext=0x10000', '--defsym=dcache_op_all=0x20000',
                            '-e', 'standby_host_delay', out / 'mmu.o', '-o', out / 'mmu.elf'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text',
                            out / 'mmu.elf', out / 'mmu.bin'], check=True)
            code = bytearray((out / 'mmu.bin').read_bytes())
            self.assertEqual(len(code), 198)
            assembly = subprocess.check_output([CROSS + 'objdump', '-d', out / 'mmu.elf'], text=True)
            self.assertEqual(assembly.count('blx\t20000 <dcache_op_all>'), 2)
            for offset in (0x36, 0x5c):
                code[offset:offset + 4] = bytes(4)
            self.assertEqual(hashlib.sha256(code).hexdigest(),
                             '08d4f7b2ca2e8fdde087e2537b4583159d5b452dbb747b2302e9648ff311ebda')
            (out / 'test.c').write_text('''
#include <unistd.h>
extern unsigned standby_host_delay(unsigned);
void dcache_op_all(void) { _exit(99); } /* Test trap: privileged paths must not execute. */
int main(void) {
    unsigned values[] = {0, 1, 4, 5, 0xffffffff, 0xdeadbeef};
    unsigned i;
    for (i = 0; i < sizeof(values)/sizeof(values[0]); ++i)
        if (standby_host_delay(values[i]) != values[i]) return 1;
    return 0;
}
''')
            subprocess.run([CROSS + 'gcc', '-static', '-O2', out / 'test.c', out / 'mmu.o',
                            '-o', out / 'test'], check=True)
            subprocess.run(['qemu-arm', out / 'test'], check=True, timeout=10)


if __name__ == '__main__':
    unittest.main()
