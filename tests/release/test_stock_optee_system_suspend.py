"""Check PSCI wrapper bytes and execute it through the real recovered caller/type reader."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
SOURCE = ROOT / 'vendor/optee/standby-host-src/system-suspend.c'


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class SystemSuspendTests(unittest.TestCase):
    def test_wrapper_bytes_unwind_and_complete_parameter_path(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            (out / 'sm').mkdir()
            (out / 'sm/psci.h').write_text('''
#include <stdint.h>
struct sm_nsec_ctx { uint32_t saved[31]; uint32_t mon_lr; uint32_t mon_spsr; };
int psci_system_suspend(uintptr_t, uint32_t, struct sm_nsec_ctx *);
''')
            subprocess.run([CROSS + 'gcc', '-c', '-Os', '-mthumb', '-mcpu=cortex-a7',
                            '-ffunction-sections', '-funwind-tables', '-I' + str(out), SOURCE,
                            '-o', out / 'suspend.o'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.psci_system_suspend',
                            out / 'suspend.o', out / 'suspend.bin'], check=True)
            body = bytearray((out / 'suspend.bin').read_bytes())
            self.assertEqual(len(body), 28)
            rel = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'suspend.o'], text=True)
            text = rel.split("Relocation section '.rel.text.psci_system_suspend'",1)[1].split('Relocation section',1)[0]
            rows = re.findall(r'^([0-9a-f]{8})\s+\S+\s+(R_ARM_\S+)\s+\S+\s+(.+)$', text, re.MULTILINE)
            self.assertEqual([(int(o,16),k,n) for o,k,n in rows],
                             [(6,'R_ARM_THM_CALL','standby_system_suspend_hook'),
                              (0x10,'R_ARM_THM_CALL','standby_host_suspend'),
                              (0x18,'R_ARM_ABS32','standby_ns_resume_entry')])
            for off, _, _ in rows:
                off = int(off,16); body[off:off+4] = bytes(4)
            self.assertEqual(hashlib.sha256(body).hexdigest(), '74695e7c022a44e39e670b6d8bc752fbd3181c9bec05c3a6fa5433c75f5fbecd')
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.ARM.exidx.text.psci_system_suspend',
                            out / 'suspend.o', out / 'unwind.bin'], check=True)
            self.assertEqual((out / 'unwind.bin').read_bytes()[4:8], bytes.fromhex('a908b180'))
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.standby_system_suspend_hook',
                            out / 'suspend.o', out / 'hook.bin'], check=True)
            self.assertEqual((out / 'hook.bin').read_bytes(), bytes.fromhex('7047'))
            subprocess.run([CROSS + 'gcc', '-static', '-O2', '-mthumb', '-mcpu=cortex-a7',
                            '-fno-builtin', '-Wall', '-Wextra', '-DTEST_PSCI_WRAPPER', '-I' + str(out),
                            '-Wl,-Ttext-segment=0x400000', SOURCE,
                            ROOT / 'tests/release/stock_optee_host_suspend_guest.c',
                            ROOT / 'tests/release/stock_optee_host_suspend_fixture.S',
                            ROOT / 'vendor/optee/standby-host-src/suspend.S',
                            ROOT / 'vendor/optee/standby-host-src/type.S', '-o', out / 'guest'], check=True)
            subprocess.run(['qemu-arm', out / 'guest'], check=True, timeout=15)


if __name__ == '__main__':
    unittest.main()
