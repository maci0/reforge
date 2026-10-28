"""Check standby loop bytes, register behavior and requested delay counts."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'vendor/optee/standby-src'
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class StandbyDelayTests(unittest.TestCase):
    def test_instruction_bytes_registers_and_count_scaling(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            for name in ('spin', 'delay'):
                subprocess.run([CROSS + 'gcc', '-c', '-marm', '-march=armv7-a',
                                SOURCE / (name + '.S'), '-o', out / (name + '.o')], check=True)
            expected = {
                'standby_delay_repeat17': ('spin',40,[], '422f95b129ccbd8aa840559707c2f8aaf483c5d20bf56dab334feef15f62f58f'),
                'standby_delay_cycles': ('spin',12,[], '0771f5a29eb0b0bc129b4080f19aa5e1c5e6084eb10951dca48e8b1d733669fa'),
                'standby_delay_us': ('delay',8,[4], '22f66107c44ea8d006bed2b9913a6478f47daed08d484580b8a578227a161866'),
                'standby_delay_ms': ('delay',56,[24,52], 'fb3c1ee7b84f8f2acb627dde35e1e4e58a5a0d5b4a406e491d4cac025e4ed342'),
            }
            for name, (obj, length, offsets, digest) in expected.items():
                path = out / (name + '.text')
                subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.' + name,
                                out / (obj + '.o'), path], check=True)
                data = bytearray(path.read_bytes())
                self.assertEqual(len(data), length)
                rel = subprocess.check_output([CROSS + 'readelf', '-rW', out / (obj + '.o')], text=True)
                section = "'.rel.text." + name + "'"
                found = []
                if section in rel:
                    body = rel.split(section, 1)[1].split('Relocation section', 1)[0]
                    found = [int(x,16) for x in re.findall(r'^([0-9a-f]{8})\s', body, re.M)]
                    self.assertIn('standby_delay_cycles', body)
                self.assertEqual(found, offsets)
                for offset in found:
                    data[offset:offset + 4] = b'\0' * 4
                self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
            (out / 'loops.c').write_text(r'''
#include <stdint.h>
extern void probe_cycles(uint32_t, uint32_t *);
extern void probe_repeat(uint32_t, uint32_t *);
int main(void) {
    uint32_t result[4]; unsigned n;
    for (n = 0; n < 18; ++n) {
        probe_cycles(n, result);
        if (result[0] != (n ? 0 : 0xffffffff) || result[1] != 0x11 || result[2] != 0x22 || result[3] != 0x33) return 1;
        probe_repeat(n, result);
        if (result[0] != n || result[1] != 0x11 || result[2] != 0x22 || result[3] != 0x33) return 2;
    }
    return 0;
}
__asm__(".text\n.arm\n"
".global probe_cycles\nprobe_cycles:\npush {r4,lr}\nmov r4,r1\nmov r1,#0x11\nmov r2,#0x22\nmov r3,#0x33\n"
"bl standby_delay_cycles\nstm r4,{r0-r3}\npop {r4,pc}\n"
".global probe_repeat\nprobe_repeat:\npush {r4,lr}\nmov r4,r1\nmov r1,#0x11\nmov r2,#0x22\nmov r3,#0x33\n"
"bl standby_delay_repeat17\nstm r4,{r0-r3}\npop {r4,pc}\n"
".global _start\n_start:\nbl main\nmov r7,#1\nsvc #0\n");
''')
            (out / 'counts.c').write_text(r'''
#include <stdint.h>
#include "delay.h"
static uint32_t counts[4], calls;
void standby_delay_cycles(uint32_t count) { if (calls < 4) counts[calls] = count; ++calls; }
static int check_ms(uint32_t ms, uint32_t n, uint32_t a, uint32_t b, uint32_t c) {
    calls = 0; standby_delay_ms(ms);
    return calls != n || counts[0] != a || (n > 1 && counts[1] != b) || (n > 2 && counts[2] != c);
}
int main(void) {
    calls = 0; standby_delay_us(0); if (calls != 1 || counts[0]) return 1;
    calls = 0; standby_delay_us(5); if (calls != 1 || counts[0] != 20) return 2;
    calls = 0; standby_delay_us(0x40000000); if (calls != 1 || counts[0]) return 3;
    calls = 0; standby_delay_us(0x80000001); if (calls != 1 || counts[0] != 4) return 4;
    if (check_ms(0,1,0,0,0)) return 5;
    if (check_ms(1,1,4000,0,0)) return 6;
    if (check_ms(10,1,40000,0,0)) return 7;
    if (check_ms(11,2,40000,4000,0)) return 8;
    if (check_ms(20,2,40000,40000,0)) return 9;
    if (check_ms(21,3,40000,40000,4000)) return 10;
    if (check_ms(25,3,40000,40000,20000)) return 11;
    return 0;
}
__asm__(".text\n.arm\n.global _start\n_start:\nbl main\nmov r7,#1\nsvc #0\n");
''')
            for name, obj in [('loops','spin'), ('counts','delay')]:
                subprocess.run([CROSS + 'gcc', '-nostdlib', '-static', '-marm', '-O2', '-fno-builtin',
                                '-I' + str(SOURCE), '-Wl,-e,_start', out / (name + '.c'),
                                out / (obj + '.o'), '-o', out / name], check=True)
                subprocess.run(['qemu-arm', out / name], check=True)


if __name__ == '__main__':
    unittest.main()
