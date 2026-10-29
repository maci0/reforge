"""Compare the recovered type reader and exercise every low-byte flag combination."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
SOURCE = ROOT / 'vendor/optee/standby-host-src/type.S'


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class HostTypeTests(unittest.TestCase):
    def test_instructions_flag_selection_and_diagnostic(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            subprocess.run([CROSS + 'gcc', '-c', SOURCE, '-o', out / 'type.o'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.standby_host_get_type',
                            out / 'type.o', out / 'type.bin'], check=True)
            code = bytearray((out / 'type.bin').read_bytes())
            self.assertEqual(len(code), 52)
            relocations = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'type.o'], text=True)
            self.assertEqual(relocations.count('R_ARM_'), 4)
            for offset, kind, target in [(0x16,'R_ARM_THM_CALL','trace_printf'),
                                         (0x28,'R_ARM_ABS32','standby_host_request'),
                                         (0x2c,'R_ARM_ABS32','.rodata.standby_host_get_type'),
                                         (0x30,'R_ARM_ABS32','.rodata.standby_host_get_type')]:
                row = next(line for line in relocations.splitlines() if line.startswith(f'{offset:08x} '))
                self.assertIn(kind, row); self.assertIn(target, row)
                code[offset:offset + 4] = bytes(4)
            self.assertEqual(hashlib.sha256(code).hexdigest(),
                             'f05d2d09e6a71401ebcb9ecd4874b2ceb312f93d5af3c819cda47a69579eb0c6')
            (out / 'test.c').write_text('''
#include <stdint.h>
#include <string.h>
#include <unistd.h>
extern unsigned standby_host_get_type(void);
uint32_t standby_host_request[2];
static unsigned logs;
void trace_printf(const char *name, int line, int level, int prefix, const char *format, ...) {
    if (strcmp(name,"standby_type") || line != 72 || level != 3 || prefix != 1 ||
        strcmp(format,"AUDIO_STANDBY\\n")) _exit(90);
    ++logs;
}
int main(void) {
    unsigned i, k, expected;
    const uint32_t high[] = {0,0xffffff00,0x80000000,0x40000000};
    for (k = 0; k < 4; ++k) for (i = 0; i < 256; ++i) {
        standby_host_request[0] = 0x12345678;
        standby_host_request[1] = high[k] | i;
        logs = 0; expected = (i & 8) ? 2 : 1;
        if (standby_host_get_type() != expected || logs != expected - 1 ||
            standby_host_request[0] != 0x12345678 || standby_host_request[1] != (high[k] | i)) return 1;
    }
    return 0;
}
''')
            subprocess.run([CROSS + 'gcc', '-static', '-O2', out / 'test.c', SOURCE,
                            '-o', out / 'test'], check=True)
            subprocess.run(['qemu-arm', out / 'test'], check=True, timeout=10)


if __name__ == '__main__':
    unittest.main()
