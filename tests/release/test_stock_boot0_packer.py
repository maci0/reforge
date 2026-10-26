import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'tools/build/pack-stock-boot0.py'
SPEC = importlib.util.spec_from_file_location('pack_stock_boot0', SCRIPT)
PACKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKER)


class Boot0PackerTests(unittest.TestCase):
    def test_vendor_default_random_stream(self):
        self.assertEqual(list(PACKER.vendor_random_words(5)),
                         [1804289383, 846930886, 1681692777, 1714636915, 1957747793])

    def test_alignment_checksum_and_unmodified_payload(self):
        raw = bytearray(520)
        raw[4:12] = b'eGON.BT0'
        struct.pack_into('<I', raw, 16, 0x4000)
        raw[512:] = b'payload!'
        packed = PACKER.pack(raw)
        self.assertEqual(len(packed), 0x4000)
        self.assertEqual(packed[512:520], b'payload!')
        checksum = struct.unpack_from('<I', packed, 12)[0]
        struct.pack_into('<I', packed, 12, 0x5f0a6c39)
        self.assertEqual(checksum, sum(x[0] for x in struct.iter_unpack('<I', packed)) & 0xffffffff)
        words = list(PACKER.vendor_random_words(0x4000 // 4))
        self.assertEqual(packed[520:], b''.join(struct.pack('<I', x) for x in words)[520:])

    def test_invalid_input_leaves_no_output(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'invalid'
            output = Path(folder) / 'output'
            source.write_bytes(b'invalid')
            result = subprocess.run([sys.executable, SCRIPT, source, output], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_existing_output_remains_untouched(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'raw'
            output = Path(folder) / 'output'
            raw = bytearray(512)
            raw[4:12] = b'eGON.BT0'
            struct.pack_into('<I', raw, 16, 0x4000)
            source.write_bytes(raw)
            output.write_bytes(b'keep')
            result = subprocess.run([sys.executable, SCRIPT, source, output], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_bytes(), b'keep')


if __name__ == '__main__':
    unittest.main()
