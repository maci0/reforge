"""Compile the generated-payload wrapper and check its complete observed alignment tail."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / 'vendor/optee/stock-patches/0008-source-standby-wrapper.patch'
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')


@unittest.skipUnless(shutil.which(CROSS + 'gcc'), 'pinned Linaro 5.3.1 required')
class StandbyWrapperTests(unittest.TestCase):
    def test_source_payload_nop_zero_alignment_and_symbols(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            subprocess.run([ROOT / 'tools/build/build-stock-optee-standby.sh', out / 'payload'],
                           check=True, capture_output=True, text=True, env=dict(os.environ, CROSS_COMPILE=CROSS))
            text = PATCH.read_text().split('+++ b/core/arch/arm/plat-sun8iw20p1/standby_blob.S\n', 1)[1]
            assembly = '\n'.join(line[1:] for line in text.splitlines() if line.startswith('+')) + '\n'
            (out / 'wrapper.S').write_text(assembly)
            subprocess.run([CROSS + 'gcc', '-c', '-marm', '-march=armv7-a',
                            '-DSUNXI_STANDBY_BINARY="' + str(out / 'payload/standby.bin') + '"',
                            out / 'wrapper.S', '-o', out / 'wrapper.o'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.sunxi_standby_wrapper',
                            out / 'wrapper.o', out / 'wrapper.bin'], check=True)
            payload = (out / 'payload/standby.bin').read_bytes()
            wrapper = (out / 'wrapper.bin').read_bytes()
            self.assertEqual(len(payload), 8400)
            self.assertEqual(len(wrapper), 16384)
            self.assertEqual(wrapper[:len(payload)], payload)
            self.assertEqual(hashlib.sha256(wrapper[len(payload):]).hexdigest(),
                             'c01be9b660290524d2451112765a6c4e286271edc408913ed780d5cec9ac3ddc')
            symbols = subprocess.check_output([CROSS + 'nm', '-n', out / 'wrapper.o'], text=True)
            for address, name in [('00000000', 'sunxi_standby_wrapper_start'),
                                  ('000020d0', 'sunxi_standby_payload_end'),
                                  ('00004000', 'sunxi_standby_wrapper_end')]:
                self.assertIn(address, next(line for line in symbols.splitlines() if line.endswith(' ' + name)))
            self.assertFalse(subprocess.check_output([CROSS + 'nm', '-u', out / 'wrapper.o']).strip())
            self.assertIn('There are no relocations', subprocess.check_output(
                [CROSS + 'readelf', '-rW', out / 'wrapper.o'], text=True))


if __name__ == '__main__':
    unittest.main()
