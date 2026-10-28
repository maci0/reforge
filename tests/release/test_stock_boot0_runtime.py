"""Execute the source-built division runtime without a target libc."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = os.environ.get('BOOT0_RUNTIME_CROSS', 'arm-linux-gnueabi-')


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'set BOOT0_RUNTIME_CROSS to Linaro 7.2.1; qemu-arm required')
class Boot0RuntimeTests(unittest.TestCase):
    def test_signed_unsigned_and_divide_by_zero_handler(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            objects = []
            for unit in ('udivsi3', 'divsi3', 'dvmd_lnx'):
                obj = out / (unit + '.o')
                subprocess.run([CROSS + 'gcc', '-c', '-g', '-O2', '-fPIC', '-DL_' + unit,
                                ROOT / 'vendor/runtime/gcc-7.2.0-arm/lib1funcs.S', '-o', obj], check=True)
                objects.append(obj)
            source = out / 'test.c'
            source.write_text(r'''
extern unsigned __udivsi3(unsigned, unsigned);
extern int __divsi3(int, int);
extern int __aeabi_idiv0(int);
static volatile int raised;
int raise(int signal) { raised = signal; return 0; }
int main(void) {
    static const unsigned u[][3] = {
        {0, 1, 0}, {1, 2, 0}, {7, 3, 2}, {0xffffffffu, 1, 0xffffffffu},
        {0xffffffffu, 0x80000000u, 1}, {0x80000000u, 3, 715827882u}
    };
    static const int s[][3] = {
        {7, 3, 2}, {-7, 3, -2}, {7, -3, -2}, {-7, -3, 2},
        {(-2147483647-1), 1, (-2147483647-1)}, {2147483647, -2, -1073741823}
    };
    unsigned i;
    for (i = 0; i < sizeof(u)/sizeof(u[0]); ++i)
        if (__udivsi3(u[i][0], u[i][1]) != u[i][2]) return 1;
    for (i = 0; i < sizeof(s)/sizeof(s[0]); ++i)
        if (__divsi3(s[i][0], s[i][1]) != s[i][2]) return 2;
    __aeabi_idiv0(0);
    return raised != 8;
}
__asm__(".text\n.arm\n.global _start\n_start:\nbl main\nmov r7,#1\nsvc #0\n");
''')
            binary = out / 'test'
            subprocess.run([CROSS + 'gcc', '-nostdlib', '-static', '-marm', '-O2',
                            '-Wl,-e,_start', source, *objects, '-o', binary], check=True)
            subprocess.run(['qemu-arm', binary], check=True)


if __name__ == '__main__':
    unittest.main()
