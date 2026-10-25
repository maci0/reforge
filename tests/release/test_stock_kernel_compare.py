"""Exercise the real stock-profile table format without storing firmware fixtures."""

import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / 'tools/build/compare-stock-kernel.py'
SPEC = importlib.util.spec_from_file_location('compare_stock_kernel', SCRIPT)
COMPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPARE)


def fixture():
    count = COMPARE.SYMBOL_COUNT
    data = bytearray(64)
    data[4:40] = COMPARE.BUILD_ID_HEADER + bytes(range(20))
    data.extend(struct.pack(f'<{count}I', *range(0, count * 4, 4)))
    data.extend(struct.pack('<II', COMPARE.IMAGE_BASE, count))
    data.extend(b'\x01\x00\x01\x02' + b'\x01\x01' * (count - 2))
    data.extend(bytes((-len(data)) % 4))
    markers = range(0, count * 2, 512)
    data.extend(struct.pack(f'<{len(markers)}I', *markers))
    tokens = [b'T_text', b'tprivate.00001', b'Tpublic.00001'] + [b''] * 253
    offsets = []
    token_table = bytearray()
    for token in tokens:
        offsets.append(len(token_table))
        token_table.extend(token + b'\0')
    data.extend(token_table)
    data.extend(bytes((-len(data)) % 2))
    data.extend(struct.pack('<256H', *offsets))
    data.extend(bytes(32))
    return bytes(data)


class StockKernelCompareTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image = fixture()
        decoded = COMPARE.decode_kallsyms(cls.image)
        cls.layout = decoded['layout']
        cls.names_end = decoded['validated_zero_alignment']['names_end']

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.stock = Path(self.directory.name) / 'stock.Image'
        self.candidate = Path(self.directory.name) / 'candidate.Image'
        self.report = Path(self.directory.name) / 'report.json'
        self.stock.write_bytes(self.image)

    def compare(self, candidate):
        self.candidate.write_bytes(candidate)
        result = COMPARE.compare(self.stock, self.candidate)
        self.assertEqual(self.stock.read_bytes(), self.image)
        self.assertEqual(self.candidate.read_bytes(), candidate)
        return result

    def test_identical_and_cli_exit_status(self):
        self.candidate.write_bytes(self.image)
        process = subprocess.run([sys.executable, SCRIPT, self.stock, self.candidate,
                                  self.report], capture_output=True, text=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        result = json.loads(self.report.read_text())
        self.assertTrue(result['full_file_equal'])
        self.assertTrue(result['payload_equal'])
        self.assertEqual(result['symbol_count'], 72471)

    def test_private_uid_and_build_id_are_provenance_only(self):
        candidate = bytearray(self.image.replace(b'tprivate.00001', b'tprivate.00002'))
        candidate[20:40] = bytes(reversed(range(20)))
        result = self.compare(bytes(candidate))
        self.assertFalse(result['full_file_equal'])
        self.assertTrue(result['payload_equal'])
        self.assertNotEqual(result['stock']['build_id'], result['candidate']['build_id'])
        self.assertEqual(result['symbol_differences']['permitted_private_uid_count'],
                         COMPARE.SYMBOL_COUNT - 2)
        self.assertEqual(result['symbol_differences']['normalized_count'], 0)
        self.assertEqual(result['outside_validated_metadata_byte_differences']['count'], 0)
        self.assertGreater(result['full_file_byte_differences']['count'], 0)

    def test_code_byte_mutation_fails_and_cli_returns_one(self):
        candidate = bytearray(self.image)
        candidate[0] = 1
        result = self.compare(bytes(candidate))
        self.assertFalse(result['payload_equal'])
        self.assertEqual(result['full_file_byte_differences']['first_offset'], 0)
        self.assertEqual(result['outside_validated_metadata_byte_differences']['count'], 1)
        process = subprocess.run([sys.executable, SCRIPT, self.stock, self.candidate,
                                  self.report], capture_output=True)
        self.assertEqual(process.returncode, 1)

    def test_address_change_fails_even_inside_excluded_table(self):
        candidate = bytearray(self.image)
        struct.pack_into('<I', candidate, self.layout['offsets_start'] + 20 * 4, 81)
        result = self.compare(bytes(candidate))
        self.assertFalse(result['payload_equal'])
        self.assertEqual(result['symbol_differences']['normalized_count'], 1)

    def test_global_uid_local_prefix_and_type_cannot_change(self):
        for before, after in [(b'Tpublic.00001', b'Tpublic.00002'),
                              (b'tprivate.00001', b'tprivatf.00001'),
                              (b'tprivate.00001', b'Tprivate.00001')]:
            with self.subTest(after=after):
                result = self.compare(self.image.replace(before, after))
                self.assertFalse(result['payload_equal'])
                self.assertGreater(result['symbol_differences']['normalized_count'], 0)

    def test_valid_tables_at_different_offsets_cannot_hide_a_gap(self):
        result = self.compare(self.image[:64] + bytes(4) + self.image[64:])
        self.assertFalse(result['validation_errors'])
        self.assertFalse(result['metadata_layout_equal'])
        self.assertFalse(result['payload_equal'])

    def test_valid_name_compression_can_use_the_zero_alignment_byte(self):
        record = self.layout['names_start'] + 4
        marker_start = self.layout['markers_start']
        candidate = bytearray(self.image[:record] + b'\x02\x01\xff'
                              + self.image[record + 2:self.names_end]
                              + bytes(marker_start - self.names_end - 1)
                              + self.image[marker_start:])
        for index in range(1, (COMPARE.SYMBOL_COUNT + 255) // 256):
            struct.pack_into('<I', candidate, marker_start + index * 4, index * 512 + 1)
        result = self.compare(bytes(candidate))
        self.assertTrue(result['payload_equal'])
        self.assertTrue(result['metadata_layout_equal'])
        self.assertNotEqual(result['stock']['validated_zero_alignment'],
                            result['candidate']['validated_zero_alignment'])

    def test_malformed_bounds_markers_index_and_alignment_fail_closed(self):
        malformed = [self.image[:self.layout['index_start'] + 510]]
        for offset in [self.layout['markers_start'], self.layout['index_start'],
                       self.layout['names_start'], self.names_end]:
            candidate = bytearray(self.image)
            candidate[offset] ^= 1
            malformed.append(bytes(candidate))
        candidate = bytearray(self.image)
        struct.pack_into('<I', candidate, self.layout['offsets_start'] + 20 * 4,
                         0xFFFFFFFF)
        malformed.append(bytes(candidate))
        for candidate in malformed:
            with self.subTest(length=len(candidate)):
                result = self.compare(candidate)
                self.assertFalse(result['payload_equal'])
                self.assertIn('candidate', result['validation_errors'])

    def test_unique_complete_gnu_note_is_required(self):
        bad_header = bytearray(self.image)
        bad_header[4] = 5
        for candidate in [bytes(bad_header),
                          self.image + COMPARE.BUILD_ID_HEADER + bytes(20)]:
            with self.subTest(length=len(candidate)):
                result = self.compare(candidate)
                self.assertFalse(result['payload_equal'])
                self.assertIn('candidate', result['validation_errors'])

    def test_report_cannot_overwrite_either_input_or_an_alias(self):
        self.candidate.write_bytes(self.image)
        symlink = Path(self.directory.name) / 'symlink'
        symlink.symlink_to(self.stock)
        hardlink = Path(self.directory.name) / 'hardlink'
        os.link(self.candidate, hardlink)
        for report in [self.stock, self.candidate, symlink, hardlink]:
            with self.subTest(report=report):
                process = subprocess.run([sys.executable, SCRIPT, self.stock,
                                          self.candidate, report], capture_output=True)
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(self.stock.read_bytes(), self.image)
                self.assertEqual(self.candidate.read_bytes(), self.image)


if __name__ == '__main__':
    unittest.main()
