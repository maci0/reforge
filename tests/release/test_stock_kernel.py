#!/usr/bin/env python3
"""Protect existing kernel outputs and references from reconstruction builds."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'tools/build/build-bsp-kernel-stock.sh'


class StockKernelTest(unittest.TestCase):
    def test_existing_output_is_preserved_before_any_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'output'
            output.mkdir()
            reference = output / 'Image.stock'
            reference.write_bytes(b'original kernel reference')
            result = subprocess.run(
                ['bash', str(SCRIPT), *([str(reference)] * 4)],
                env={**os.environ, 'OUT': str(output), 'STOCK_REF': str(reference)},
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Output directory must be new', result.stderr)
            self.assertEqual(reference.read_bytes(), b'original kernel reference')
            self.assertEqual(list(output.iterdir()), [reference])


if __name__ == '__main__':
    unittest.main()
