#!/usr/bin/env python3
"""Protect original bootloader references from build-output overwrites."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / 'tools/build/build-stock-uboot.sh'


class StockUbootTest(unittest.TestCase):
    def test_existing_output_cannot_overwrite_reference(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            # No compiler executes: discovery alone precedes the output guard.
            prefix = str(root / 'arm-test-')
            for name in ('gcc', 'ld.bfd', 'objcopy'):
                tool = Path(prefix + name)
                tool.write_text('#!/bin/sh\nexit 99\n')
                tool.chmod(0o755)
            sdk = root / 'source.zip'
            sdk.write_bytes(b'not read before the output guard')
            output = root / 'output'
            output.mkdir()
            reference = output / 'u-boot.bin'
            reference.write_bytes(b'original firmware reference')
            result = subprocess.run(
                ['bash', str(SCRIPT), str(sdk), prefix, str(reference), str(output)],
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('output directory must be new', result.stderr)
            self.assertEqual(reference.read_bytes(), b'original firmware reference')
            self.assertEqual(list(output.iterdir()), [reference])


if __name__ == '__main__':
    unittest.main()
