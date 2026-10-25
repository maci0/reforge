#!/usr/bin/env python3
"""Protect bootloader references and validate stock-compatible image packing."""
from pathlib import Path
import subprocess
import importlib.util
import struct
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / 'tools/build/build-stock-uboot.sh'
SPEC = importlib.util.spec_from_file_location('stock_uboot_image', REPO / 'tools/build/stock-uboot-image.py')
IMAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMAGE)


class StockUbootTest(unittest.TestCase):
    def test_unpinned_source_is_rejected_before_compiling(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            prefix = str(root / 'arm-test-')
            for name in ('gcc', 'ld.bfd', 'objcopy'):
                tool = Path(prefix + name)
                tool.write_text('#!/bin/sh\nexit 99\n')
                tool.chmod(0o755)
            source = root / 'source.zip'
            source.write_bytes(b'wrong or altered source')
            reference = root / 'stock.bin'
            reference.write_bytes(b'original reference')
            output = root / 'output'
            result = subprocess.run(
                ['bash', str(SCRIPT), str(source), prefix, str(reference), str(output)],
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('source archive SHA-256 mismatch', result.stderr)
            self.assertEqual(reference.read_bytes(), b'original reference')
            self.assertFalse((output / 'u-boot.bin').exists())

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


class StockImagePackingTest(unittest.TestCase):
    def setUp(self):
        self.dtb = (struct.pack('>10I', 0xD00DFEED, 72, 56, 72, 40, 17, 16, 0, 0, 16)
                    + bytes(16) + struct.pack('>4I', 1, 0, 2, 9))
        self.core = bytearray(2048)
        self.core[4:12] = b'uboot\0\0\0'
        struct.pack_into('<I', self.core, 16, 0x4000)
        self.core[0x600:] = b'\x55' * (len(self.core) - 0x600)
        reference = self.core + self.dtb
        reference += b'\xff' * (0x4000 - len(reference))
        struct.pack_into('<II', reference, 20, len(reference), len(reference))
        struct.pack_into('<I', reference, 12, IMAGE.checksum(reference))
        self.reference = bytes(reference)

    def test_extract_and_repack_original_exactly(self):
        self.assertEqual(IMAGE.reference_dtb(self.reference), self.dtb)
        self.assertEqual(IMAGE.pack(self.core, self.dtb, self.reference), self.reference)

    def test_larger_source_core_preserved_with_zero_size_delta(self):
        core = self.core + b'\x33' * 1640
        packed = IMAGE.pack(core, self.dtb, self.reference)
        self.assertEqual(len(packed), len(self.reference))
        self.assertEqual(packed[28:len(core)], core[28:])
        self.assertEqual(packed[len(core):len(core) + len(self.dtb)], self.dtb)
        self.assertEqual(packed[len(core) + len(self.dtb):], b'\xff' * (len(packed) - len(core) - len(self.dtb)))
        self.assertEqual(struct.unpack_from('<II', packed, 20), (len(packed), len(packed)))
        self.assertEqual(struct.unpack_from('<I', packed, 12)[0], IMAGE.checksum(packed))

    def test_overflow_cannot_be_truncated(self):
        with self.assertRaisesRegex(ValueError, 'refusing to truncate'):
            IMAGE.pack(self.core + bytes(0x4000), self.dtb, self.reference)

    def test_invalid_reference_checksum_rejected(self):
        bad = bytearray(self.reference)
        bad[0x700] ^= 1
        with self.assertRaisesRegex(ValueError, 'checksum'):
            IMAGE.reference_dtb(bad)

    def test_changed_control_dtb_rejected(self):
        changed = bytearray(self.dtb + b'abc\0')
        struct.pack_into('>I', changed, 4, len(changed))
        struct.pack_into('>I', changed, 32, 4)
        with self.assertRaisesRegex(ValueError, 'does not match'):
            IMAGE.pack(self.core, changed, self.reference)

    def test_truncated_dtb_rejected(self):
        with self.assertRaisesRegex(ValueError, 'layout'):
            IMAGE.validate_dtb(self.dtb[:-4])


if __name__ == '__main__':
    unittest.main()
