import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'tools/build/pack-stock-toc1.py'
SPEC = importlib.util.spec_from_file_location('pack_stock_toc1', SCRIPT)
PACKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKER)


class Toc1PackerTests(unittest.TestCase):
    def test_records_alignment_padding_and_checksum(self):
        payloads = (b'U' * 2049, b'T' * 9, b'D' * 17)
        packed = PACKER.pack(*payloads)
        self.assertEqual(len(packed), 16384)
        header = PACKER.HEADER.unpack_from(packed)
        self.assertEqual(header[:2], (b'sunxi-package\0\0\0', 0x89119800))
        self.assertEqual(header[5:7], (3, len(packed)))
        self.assertEqual(header[-1], 0x3b45494d)
        end = 64 + 3 * 368
        for i, (name, payload, offset) in enumerate(zip(
                (b'u-boot', b'optee', b'dtb'), payloads, (2048, 6144, 8192))):
            record = PACKER.ITEM.unpack_from(packed, 64 + i * 368)
            self.assertEqual(record[0].rstrip(b'\0'), name)
            self.assertEqual(record[1:7], (offset, len(payload), 0, 3, 0, 0))
            self.assertEqual(record[7:-1], (0,) * 69)
            self.assertEqual(record[-1], 0x3b454949)
            self.assertEqual(packed[offset:offset + len(payload)], payload)
            self.assertFalse(any(packed[end:offset]))
            end = offset + len(payload)
        self.assertFalse(any(packed[end:]))
        checksum = struct.unpack_from('<I', packed, 20)[0]
        struct.pack_into('<I', packed, 20, PACKER.STAMP)
        self.assertEqual(checksum, sum(w[0] for w in struct.iter_unpack('<I', packed)) & 0xffffffff)

    def test_empty_payload_rejected(self):
        for payloads in ((b'', b't', b'd'), (b'u', b'', b'd'), (b'u', b't', b'')):
            with self.assertRaises(ValueError):
                PACKER.pack(*payloads)

    def test_existing_output_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as folder:
            payload = Path(folder) / 'payload'
            output = Path(folder) / 'output'
            payload.write_bytes(b'example')
            output.write_bytes(b'keep')
            result = subprocess.run([sys.executable, SCRIPT, payload, payload, payload, output],
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_bytes(), b'keep')


if __name__ == '__main__':
    unittest.main()
