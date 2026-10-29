"""Check recovered caller encodings and execute parameter transfer with test services."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
SOURCE = ROOT / 'vendor/optee/standby-host-src/suspend.S'


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class HostSuspendTests(unittest.TestCase):
    def test_source_bytes_relocations_and_parameter_transfer(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            subprocess.run([CROSS + 'gcc', '-c', SOURCE, '-o', out / 'suspend.o'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.standby_host_suspend',
                            out / 'suspend.o', out / 'suspend.bin'], check=True)
            code = bytearray((out / 'suspend.bin').read_bytes())
            self.assertEqual(len(code), 532)
            relocations = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'suspend.o'], text=True)
            rows = re.findall(r'^([0-9a-f]{8})\s+\S+\s+(R_ARM_\S+)\s+\S+\s+(.+)$',
                              relocations, re.MULTILINE)
            calls = [int(offset, 16) for offset, kind, _ in rows if kind == 'R_ARM_THM_CALL']
            pointers = [int(offset, 16) for offset, kind, _ in rows if kind == 'R_ARM_ABS32']
            self.assertEqual(calls, [0x2,0x12,0x36,0xa6,0xb8,0xce,0xe4,0xfa,0x110,
                                     0x126,0x13c,0x152,0x168,0x184,0x196,0x19e,0x1a2,0x1b2])
            self.assertEqual(pointers, [0x1bc,0x1c0,0x1c4,0x1c8,0x1cc,0x1d4,
                                       *range(0x1d8,0x20c,4),0x210])
            self.assertEqual(len(rows), 38)
            for offset, _, _ in rows:
                start = int(offset, 16)
                code[start:start + 4] = bytes(4)
            self.assertEqual(hashlib.sha256(code).hexdigest(),
                             'f1578c88d781ac9d9bf3787bd268507c6de0d76ea93a7956fec52e7415b8e296')
            subprocess.run([CROSS + 'gcc', '-static', '-O2', '-mthumb', '-march=armv7-a',
                            '-fno-builtin', '-Wall', '-Wextra', '-Wl,-Ttext-segment=0x400000',
                            ROOT / 'tests/release/stock_optee_host_suspend_guest.c',
                            ROOT / 'tests/release/stock_optee_host_suspend_fixture.S', SOURCE,
                            ROOT / 'vendor/optee/standby-host-src/type.S',
                            '-o', out / 'guest'], check=True)
            subprocess.run(['qemu-arm', out / 'guest'], check=True, timeout=15)


if __name__ == '__main__':
    unittest.main()
