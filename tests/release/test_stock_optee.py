"""Check reconstruction input rejection without compiling target code."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools/build/build-stock-optee.sh'


class OpteeBuildTest(unittest.TestCase):
    def test_existing_output_is_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'source.tar.gz'
            archive.write_bytes(b'not the pinned source')
            output = root / 'output'
            output.mkdir()
            sentinel = output / 'keep'
            sentinel.write_text('existing output')
            result = subprocess.run(['bash', str(SCRIPT), str(archive), str(output)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Output directory must be new', result.stderr)
            self.assertEqual(list(output.iterdir()), [sentinel])
            self.assertEqual(sentinel.read_text(), 'existing output')

    def test_wrong_source_cannot_create_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'source.tar.gz'
            archive.write_bytes(b'not the pinned source')
            output = root / 'output'
            result = subprocess.run(['bash', str(SCRIPT), str(archive), str(output)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('OP-TEE source archive SHA-256 mismatch', result.stderr)
            self.assertFalse(output.exists())
            self.assertEqual(archive.read_bytes(), b'not the pinned source')


if __name__ == '__main__':
    unittest.main()
