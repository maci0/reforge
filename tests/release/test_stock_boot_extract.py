#!/usr/bin/env python3
"""Test primary boot reference extraction without a printer or firmware archive."""
import gzip
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    'stock_boot_extract', REPO / 'tools/recovery/extract-stock-boot.py')
EXTRACTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXTRACTOR)


def checksum(data, offset):
    struct.pack_into('<I', data, offset, EXTRACTOR.CHECKSUM_STAMP)
    value = sum(word[0] for word in struct.iter_unpack('<I', data)) & 0xFFFFFFFF
    struct.pack_into('<I', data, offset, value)


def image():
    boot0 = bytearray(256)
    boot0[4:12] = b'eGON.BT0'
    struct.pack_into('<II', boot0, 16, len(boot0), 48)
    checksum(boot0, 12)
    toc = bytearray(4096)
    toc[:16] = b'sunxi-package\0\0\0'
    struct.pack_into('<I', toc, 16, EXTRACTOR.TOC_MAGIC)
    struct.pack_into('<II', toc, 32, 3, len(toc))
    struct.pack_into('<I', toc, 60, EXTRACTOR.TOC_END)
    for i, name in enumerate(EXTRACTOR.MEMBERS):
        base = 64 + i * EXTRACTOR.ITEM_SIZE
        toc[base:base + len(name)] = name.encode()
        offset = 2048 + i * 128
        struct.pack_into('<4I', toc, base + 64, offset, 128, 0, 3)
        struct.pack_into('<I', toc, base + 364, EXTRACTOR.ITEM_END)
        toc[offset:offset + 128] = bytes([i + 1]) * 128
    checksum(toc, 20)
    return boot0, toc


class StockBootExtractTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'image.bin'
        self.output = self.root / 'reference'
        self.boot0, self.toc = image()

    def write(self):
        with self.source.open('wb') as stream:
            stream.seek(EXTRACTOR.BOOT0_OFFSET)
            stream.write(self.boot0)
            stream.seek(EXTRACTOR.TOC_OFFSET)
            stream.write(self.toc)

    def test_plain_and_gzip_reference_extraction(self):
        self.write()
        compressed = self.root / 'image.gz'
        with self.source.open('rb') as source, gzip.open(compressed, 'wb') as target:
            while chunk := source.read(1024 * 1024):
                target.write(chunk)
        for source in (self.source, compressed):
            with self.subTest(source=source.name):
                output = self.root / (source.name + '-reference')
                manifest = EXTRACTOR.extract(source, output)
                self.assertIn('reference-only', manifest['purpose'])
                self.assertEqual((output / 'u-boot.bin').read_bytes(), bytes([1]) * 128)
                self.assertEqual((output / 'boot0.bin').read_bytes(), self.boot0)
                self.assertEqual(json.loads((output / 'manifest.json').read_text()), manifest)

    def test_bad_checksum_rejected_without_output(self):
        self.toc[-1] ^= 1
        self.write()
        with self.assertRaisesRegex(ValueError, 'checksum'):
            EXTRACTOR.extract(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_boot0_length_rejected(self):
        struct.pack_into('<I', self.boot0, 16, 0x20000)
        self.write()
        with self.assertRaisesRegex(ValueError, 'boot0: invalid length'):
            EXTRACTOR.extract(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_member_range_rejected_after_valid_checksum(self):
        struct.pack_into('<I', self.toc, 64 + 64, len(self.toc) - 4)
        checksum(self.toc, 20)
        self.write()
        with self.assertRaisesRegex(ValueError, 'range'):
            EXTRACTOR.extract(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_overlapping_members_rejected(self):
        struct.pack_into('<I', self.toc, 64 + EXTRACTOR.ITEM_SIZE + 64, 2048)
        checksum(self.toc, 20)
        self.write()
        with self.assertRaisesRegex(ValueError, 'overlaps'):
            EXTRACTOR.extract(self.source, self.output)

    def test_truncated_image_rejected(self):
        self.write()
        with self.source.open('r+b') as stream:
            stream.truncate(EXTRACTOR.TOC_OFFSET + 100)
        with self.assertRaisesRegex(ValueError, 'truncated'):
            EXTRACTOR.extract(self.source, self.output)

    def test_existing_destination_not_overwritten(self):
        self.output.mkdir()
        marker = self.output / 'keep'
        marker.write_text('untouched')
        with self.assertRaises(FileExistsError):
            EXTRACTOR.extract(self.source, self.output)
        self.assertEqual(marker.read_text(), 'untouched')


if __name__ == '__main__':
    unittest.main()
