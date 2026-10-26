"""Verify recovered configuration builds against independent stock artifact pins."""
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('board_data', ROOT / 'tools/build/build-stock-board-data.py')
BOARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOARD)


class BoardDataTest(unittest.TestCase):
    def test_environment_crc_flag_order_and_padding(self):
        data = BOARD.environment('a=one\nb=two spaces  here\n')
        self.assertEqual(len(data), 1024 * 1024)
        self.assertEqual(data[4], 1)
        records = b'a=one\0b=two spaces  here\0\0'
        self.assertEqual(data[5:5 + len(records)], records)
        self.assertEqual(set(data[5 + len(records):131072]), {0})
        self.assertEqual(struct.unpack_from('<I', data)[0], zlib.crc32(data[5:131072]))
        self.assertEqual(set(data[131072:]), {0})

    def test_invalid_environment_is_rejected(self):
        for text in ('a=1\na=2\n', '=missing-name\n', 'missing-value-marker\n',
                     'a=embedded\0nul\n', 'a=' + 'x' * 131067):
            with self.subTest(text=text[:30]), self.assertRaises(ValueError):
                BOARD.environment(text)

    @unittest.skipUnless(shutil.which('dtc'), 'dtc is required for source configuration builds')
    def test_full_stock_configuration_hashes_and_no_overwrite(self):
        manifest = json.loads((ROOT / 'docs/board-notes/stock-boot-artifacts.json').read_text())
        pins = {x['name']: x['sha256'] for x in manifest['artifacts']}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'board'
            report = BOARD.build(output)
            for target, reference in [('sunxi.dtb', 'p1-sunxi.dtb'), ('toc-padded.dtb', 'dtb'),
                                      ('u-boot-control.dtb', 'u-boot-control-0xe3aa0.dtb'),
                                      ('env.bin', 'env'), ('env-redund.bin', 'env-redund')]:
                self.assertEqual(report['artifacts'][target]['sha256'], pins[reference])
            before = (output / 'comparison.json').read_bytes()
            with self.assertRaises(FileExistsError):
                BOARD.build(output)
            self.assertEqual((output / 'comparison.json').read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
