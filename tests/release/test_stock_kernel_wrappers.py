#!/usr/bin/env python3
"""Check legacy wrapper metadata, CRC rejection and reference preservation."""
import binascii
import importlib.util
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'tools/build/stock-kernel-wrappers.py'
SPEC = importlib.util.spec_from_file_location('stock_kernel_wrappers', SCRIPT)
WRAPPERS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WRAPPERS)


class KernelWrappersTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.zimage = self.root / 'zImage'
        data = bytearray(96)
        struct.pack_into('<III', data, 36, 0x016F2818, 0, len(data))
        data[64:] = bytes(range(32))
        self.zimage.write_bytes(data)
        self.uimage = self.root / 'uImage'

    def test_pack_preserves_payload_and_original_metadata(self):
        WRAPPERS.pack(self.zimage, self.uimage)
        data = self.uimage.read_bytes()
        fields = struct.unpack('>7I4B32s', data[:64])
        self.assertEqual(data[64:], self.zimage.read_bytes())
        self.assertEqual(fields[0], 0x27051956)
        self.assertEqual(fields[2:6], (1692776025, 96, 0x40008000, 0x40008000))
        self.assertEqual(fields[7:11], (5, 2, 2, 0))
        self.assertEqual(fields[11].rstrip(b'\0'), b'Linux-5.4.61')
        header = bytearray(data[:64])
        header[4:8] = bytes(4)
        self.assertEqual(fields[1], binascii.crc32(header))
        self.assertEqual(fields[6], binascii.crc32(data[64:]))

    def test_corrupted_payload_is_rejected(self):
        WRAPPERS.pack(self.zimage, self.uimage)
        data = bytearray(self.uimage.read_bytes())
        data[-1] ^= 1
        with self.assertRaisesRegex(ValueError, 'data CRC mismatch'):
            WRAPPERS.parse(data)

    def test_existing_output_and_reference_are_preserved(self):
        self.uimage.write_bytes(b'existing reference')
        original = self.zimage.read_bytes()
        with self.assertRaises(FileExistsError):
            WRAPPERS.pack(self.zimage, self.uimage)
        self.assertEqual(self.uimage.read_bytes(), b'existing reference')
        self.assertEqual(self.zimage.read_bytes(), original)

    def test_wrong_board_reference_is_rejected_without_input_changes(self):
        WRAPPERS.pack(self.zimage, self.uimage)
        original = self.uimage.read_bytes()
        self.assertEqual(WRAPPERS.compare(self.uimage, self.uimage, self.root / 'report.json'), 1)
        self.assertEqual(self.uimage.read_bytes(), original)
        with self.assertRaises(FileExistsError):
            WRAPPERS.compare(self.uimage, self.uimage, self.uimage)
        self.assertEqual(self.uimage.read_bytes(), original)

    def test_builder_rejects_missing_or_wrong_reference_before_output_creation(self):
        script = SCRIPT.with_name('build-bsp-kernel-stock.sh')
        dummy = self.root / 'original'
        dummy.write_bytes(b'not the board reference')
        output = self.root / 'build'
        for value, message in [('', 'STOCK_UIMAGE must name'),
                               (str(dummy), 'STOCK_UIMAGE SHA-256')]:
            result = subprocess.run(['bash', str(script), *([str(dummy)] * 4), str(output)],
                                    env={**os.environ, 'STOCK_UIMAGE': value},
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)
            self.assertFalse(output.exists())
            self.assertEqual(dummy.read_bytes(), b'not the board reference')


if __name__ == '__main__':
    unittest.main()
