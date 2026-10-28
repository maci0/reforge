"""Build the published ARM runtime adaptation and verify bytes plus arithmetic ABI."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
SOURCE = ROOT / 'vendor/optee/standby-src/runtime'


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class StandbyRuntimeTests(unittest.TestCase):
    def test_full_linked_block_and_quotient_remainder_edges(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            shutil.copy2(SOURCE / 'lib1funcs.S', out / 'lib1funcs.S')
            subprocess.run(['patch', '--batch', '--fuzz=0', '-p1', '-i', SOURCE / 'standby-div0.patch'],
                           cwd=out, check=True, capture_output=True)
            subprocess.run([CROSS + 'gcc', '-c', '-marm', '-march=armv7-a', '-D__ASSEMBLY__',
                            '-D__UBOOT__', '-D__LINUX_ARM_ARCH__=7', '-I' + str(SOURCE / 'abi'),
                            out / 'lib1funcs.S', '-o', out / 'runtime.o'], check=True)
            subprocess.run([CROSS + 'ld', '-T', SOURCE / 'runtime.lds', out / 'runtime.o',
                            '-o', out / 'runtime.elf'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text', out / 'runtime.elf',
                            out / 'runtime.bin'], check=True)
            data = (out / 'runtime.bin').read_bytes()
            self.assertEqual(len(data), 420)
            self.assertEqual(hashlib.sha256(data).hexdigest(),
                             'cc0b4d9fa3eae69b01e64d454781d3e3f13de1dc691cfa919b4615d0cbea31b4')
            self.assertFalse(subprocess.check_output([CROSS + 'nm', '-u', out / 'runtime.elf'], text=True).strip())
            subprocess.run([CROSS + 'gcc', '-c', '-marm', '-march=armv7-a',
                            SOURCE.parent / 'spin.S', '-o', out / 'spin.o'], check=True)
            subprocess.run([CROSS + 'ld', '-T', SOURCE / 'with-spin.lds', out / 'spin.o',
                            out / 'runtime.o', '-o', out / 'with-spin.elf'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text', out / 'with-spin.elf',
                            out / 'with-spin.bin'], check=True)
            combined = (out / 'with-spin.bin').read_bytes()
            self.assertEqual(len(combined), 472)
            self.assertEqual(hashlib.sha256(combined).hexdigest(),
                             '6f729d0fb22652dff6ec5f42593c2fe9656d2910af8b46a63294ecd6d8726ac9')
            self.assertFalse(subprocess.check_output([CROSS + 'nm', '-u', out / 'with-spin.elf'], text=True).strip())
            (out / 'test.c').write_text(r'''
extern unsigned __aeabi_uidiv(unsigned, unsigned);
extern int __aeabi_idiv(int, int);
extern void test_uidivmod(unsigned, unsigned, unsigned *);
extern void test_idivmod(unsigned, unsigned, unsigned *);
static int check(unsigned n, unsigned d, unsigned quotient, unsigned remainder, int is_signed) {
    unsigned result[2];
    unsigned direct = is_signed ? (unsigned)__aeabi_idiv((int)n, (int)d) : __aeabi_uidiv(n, d);
    if (direct != quotient) return 1;
    if (is_signed) test_idivmod(n, d, result);
    else test_uidivmod(n, d, result);
    return result[0] != quotient || result[1] != remainder;
}
static const unsigned unsigned_cases[][4] = {
    {0,5,0,0}, {1,2,0,1}, {7,7,1,0}, {0xffffffff,1,0xffffffff,0},
    {0xffffffff,2,0x7fffffff,1}, {0xffffffff,3,0x55555555,0},
    {0x80000000,3,0x2aaaaaaa,2}, {0xffffffff,0,0,0xffffffff}
};
static const unsigned signed_cases[][4] = {
    {7,3,2,1}, {0xfffffff9,3,0xfffffffe,0xffffffff},
    {7,0xfffffffd,0xfffffffe,1}, {0xfffffff9,0xfffffffd,2,0xffffffff},
    {0xffffffff,2,0,0xffffffff}, {0x80000000,0xffffffff,0x80000000,0},
    {0,0xfffffffe,0,0}, {0xfffffff9,0,0,0xfffffff9}
};
int main(void) {
    unsigned i;
    for (i = 0; i < sizeof(unsigned_cases)/sizeof(unsigned_cases[0]); ++i)
        if (check(unsigned_cases[i][0], unsigned_cases[i][1], unsigned_cases[i][2], unsigned_cases[i][3], 0)) return 1;
    for (i = 0; i < sizeof(signed_cases)/sizeof(signed_cases[0]); ++i)
        if (check(signed_cases[i][0], signed_cases[i][1], signed_cases[i][2], signed_cases[i][3], 1)) return 2;
    return 0;
}
__asm__(".text\n.arm\n"
        ".global test_uidivmod\ntest_uidivmod:\npush {r4,lr}\nmov r4,r2\n"
        "bl __aeabi_uidivmod\nstm r4,{r0,r1}\npop {r4,pc}\n"
        ".global test_idivmod\ntest_idivmod:\npush {r4,lr}\nmov r4,r2\n"
        "bl __aeabi_idivmod\nstm r4,{r0,r1}\npop {r4,pc}\n");
__asm__(".text\n.arm\n.global _start\n_start:\nbl main\nmov r7,#1\nsvc #0\n");
''')
            subprocess.run([CROSS + 'gcc', '-nostdlib', '-static', '-marm', '-march=armv7-a',
                            '-O2', '-fno-builtin', '-ffunction-sections', '-Wl,--gc-sections',
                            '-Wl,-e,_start', out / 'test.c', out / 'runtime.o', '-o', out / 'test'], check=True)
            subprocess.run(['qemu-arm', out / 'test'], check=True)


if __name__ == '__main__':
    unittest.main()
