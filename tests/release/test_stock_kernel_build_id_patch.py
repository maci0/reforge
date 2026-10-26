"""Check the narrowly scoped metadata patch without storing a kernel fixture."""
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / 'tools/build/patch-stock-kernel-build-id.py'
SPEC = importlib.util.spec_from_file_location('kernel_id_patch', SCRIPT)
PATCHER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PATCHER)


class KernelBuildIdPatchTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        expected = bytearray(PATCHER.IMAGE_BYTES)
        expected[PATCHER.ID_OFFSET - 16:PATCHER.ID_OFFSET] = PATCHER.NOTE_HEADER
        expected[PATCHER.ID_OFFSET:PATCHER.ID_OFFSET + 20] = PATCHER.STOCK_ID
        cls.expected = bytes(expected)
        cls.pin = hashlib.sha256(cls.expected).hexdigest()
        expected[PATCHER.ID_OFFSET:PATCHER.ID_OFFSET + 20] = bytes(20)
        cls.source = bytes(expected)

    def test_only_id_changes_and_second_pass_is_identical(self):
        with patch.object(PATCHER, 'STOCK_SHA256', self.pin):
            result = PATCHER.patch(self.source)
            self.assertEqual(result, self.expected)
            self.assertEqual(result[:PATCHER.ID_OFFSET], self.source[:PATCHER.ID_OFFSET])
            self.assertEqual(result[PATCHER.ID_OFFSET + 20:], self.source[PATCHER.ID_OFFSET + 20:])
            self.assertEqual(PATCHER.patch(result), result)

    def test_code_mutation_malformed_note_and_wrong_size_are_rejected(self):
        bad_code = bytearray(self.source)
        bad_code[0] ^= 1
        bad_note = bytearray(self.source)
        bad_note[PATCHER.ID_OFFSET - 16] ^= 1
        with patch.object(PATCHER, 'STOCK_SHA256', self.pin):
            for data in (bad_code, bad_note, self.source[:-1]):
                with self.subTest(length=len(data)), self.assertRaises(ValueError):
                    PATCHER.patch(bytes(data))

    def test_cli_failure_never_creates_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / 'Image', root / 'Image.patched'
            source.write_bytes(self.source)
            result = subprocess.run([sys.executable, SCRIPT, source, output], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
            self.assertEqual(source.read_bytes(), self.source)


if __name__ == '__main__':
    unittest.main()
