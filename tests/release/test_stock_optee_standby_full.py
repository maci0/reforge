"""Build the complete source image, test strict comparison, and execute DRAM helpers."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'vendor/optee/standby-src'
BUILD = ROOT / 'tools/build/build-stock-optee-standby.sh'
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class FullStandbyTests(unittest.TestCase):
    def test_source_build_strict_gate_and_dram_snapshot(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            first, second, third, fourth = (out / name for name in ('first', 'second', 'third', 'fourth'))
            environment = dict(os.environ, CROSS_COMPILE=CROSS)
            subprocess.run([BUILD, first], check=True, capture_output=True, text=True, env=environment)
            body = (first / 'standby.bin').read_bytes()
            self.assertEqual(len(body), 8400)
            # This is the current candidate hash, not an acceptance exception for stock equality.
            self.assertEqual(hashlib.sha256(body).hexdigest(),
                             '7f058be9ae2b5e7d94c2fa951e3a62bba8dd3db24de9860bcbe7e63d2946ad86')
            subprocess.run([BUILD, second, first / 'standby.bin'], check=True, capture_output=True, text=True, env=environment)
            self.assertEqual((first / 'standby.elf').read_bytes(), (second / 'standby.elf').read_bytes())
            self.assertTrue(json.loads((second / 'comparison.json').read_text())['identical'])
            different = bytearray(body); different[-1] ^= 1
            (out / 'different.bin').write_bytes(different)
            result = subprocess.run([BUILD, third, out / 'different.bin'], capture_output=True, text=True, env=environment)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            report = json.loads((third / 'comparison.json').read_text())
            self.assertFalse(report['identical'])
            self.assertEqual(report['size_delta'], 0)
            self.assertEqual(report['differing_positions_in_shared_extent'], 1)
            (out / 'longer.bin').write_bytes(body + b'\0')
            result = subprocess.run([BUILD, fourth, out / 'longer.bin'], capture_output=True, text=True, env=environment)
            self.assertEqual(result.returncode, 1)
            report = json.loads((fourth / 'comparison.json').read_text())
            self.assertFalse(report['identical'])
            self.assertEqual(report['size_delta'], -1)
            self.assertEqual(report['differing_positions_in_shared_extent'], 0)
            result = subprocess.run([BUILD, first], capture_output=True, text=True, env=environment)
            self.assertEqual(result.returncode, 2)
            symbols = subprocess.check_output([CROSS + 'nm', '-n', first / 'standby.elf'], text=True)
            for address, symbol in [('000220d0', '__bss_start'), ('000220d4', 'standby_dram_state'),
                                    ('0002227c', 'standby_clock_saved_aux'), ('00022280', 'standby_twi_state'),
                                    ('0002228c', '__bss_end')]:
                self.assertIn(address, next(line for line in symbols.splitlines() if line.endswith(' ' + symbol)))
            subprocess.run([CROSS + 'gcc', '-static', '-O2', '-marm', '-march=armv7-a',
                            '-Wall', '-Wextra', '-I' + str(SOURCE),
                            ROOT / 'tests/release/stock_optee_standby_dram_guest.c',
                            *[first / 'objects' / (name + '.o') for name in ('dram', 'dram-state', 'memory')],
                            '-o', out / 'guest'], check=True)
            subprocess.run(['qemu-arm', out / 'guest'], check=True, timeout=15)


if __name__ == '__main__':
    unittest.main()
