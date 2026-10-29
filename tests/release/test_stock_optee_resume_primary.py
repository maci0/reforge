"""Compare primary-resume source bytes/unwind and execute with modeled CP15 state."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
SOURCE = ROOT / 'vendor/optee/standby-host-src/resume-primary.S'


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class PrimaryResumeTests(unittest.TestCase):
    def test_instructions_unwind_and_modeled_resume(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            subprocess.run([CROSS + 'gcc', '-c', SOURCE, '-o', out / 'resume.o'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.generic_boot_resume_primary',
                            out / 'resume.o', out / 'resume.bin'], check=True)
            code = bytearray((out / 'resume.bin').read_bytes())
            self.assertEqual(len(code), 84)
            rel = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'resume.o'], text=True)
            body = rel.split('Relocation section', 2)[1]
            rows = re.findall(r'^([0-9a-f]{8})\s+\S+\s+(R_ARM_\S+)\s+\S+\s+(.+)$', body, re.MULTILINE)
            expected = [(6,'R_ARM_THM_CALL','thread_set_exceptions'),
                        (0xa,'R_ARM_THM_CALL','thread_init_per_cpu'), (0x10,'R_ARM_THM_CALL','init_sec_mon'),
                        (0x14,'R_ARM_THM_CALL','main_init_gic'), (0x36,'R_ARM_THM_CALL','trace_printf'),
                        (0x3a,'R_ARM_THM_CALL','standby_resume_hook_before_return'),
                        (0x44,'R_ARM_THM_JUMP24','standby_resume_hook_tail'),
                        (0x48,'R_ARM_ABS32','standby_ns_resume_entry'),
                        (0x4c,'R_ARM_ABS32','.rodata.generic_boot_resume_primary'),
                        (0x50,'R_ARM_ABS32','.rodata.generic_boot_resume_primary')]
            self.assertEqual([(int(o,16),k,n) for o,k,n in rows], expected)
            for offset, _, _ in expected:
                code[offset:offset + 4] = bytes(4)
            self.assertEqual(hashlib.sha256(code).hexdigest(),
                             '306c859a8a45efc5a062c061eec6946c40ad6c1991df8b6667a97c2067e419cc')
            subprocess.run([CROSS + 'objcopy', '-O', 'binary',
                            '-j', '.ARM.exidx.text.generic_boot_resume_primary',
                            out / 'resume.o', out / 'unwind.bin'], check=True)
            self.assertEqual((out / 'unwind.bin').read_bytes()[4:8], bytes.fromhex('b0a80180'))
            for name in ('standby_resume_hook_before_return', 'standby_resume_hook_tail'):
                subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.' + name,
                                out / 'resume.o', out / (name + '.bin')], check=True)
                self.assertEqual((out / (name + '.bin')).read_bytes(), bytes.fromhex('7047'))
            subprocess.run([CROSS + 'gcc', '-static', '-O2', '-marm', '-march=armv7-a', '-Wall', '-Wextra',
                            ROOT / 'tests/release/stock_optee_resume_primary_guest.c', SOURCE,
                            '-o', out / 'guest'], check=True)
            subprocess.run(['qemu-arm', out / 'guest'], check=True, timeout=15)


if __name__ == '__main__':
    unittest.main()
