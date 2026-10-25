#!/usr/bin/env python3
"""Protect MCU board addressing and host/protocol identity before packaging."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
PACKAGE = REPO / 'br-external/package/klipper13'
SPEC = importlib.util.spec_from_file_location('check_mcu', PACKAGE / 'check-mcu.py')
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)
VERSION = 'v0.13.0-285-gfc2aaae69-ffadm5-reforge'


class FirmwareCheckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.output = Path(self.tmp.name)
        self.config = self.output / 'board.config'

    def fixture(self, board):
        self.config.write_bytes((PACKAGE / 'mcu-configs' / board).read_bytes())
        address = 0x08000000 if board == 'mainboard' else 0x08010000
        (self.output / 'klipper.bin').write_bytes(
            struct.pack('<II', 0x20020000, address + 0x81) + bytes(248))
        (self.output / 'klipper.dict').write_text(json.dumps({
            'version': VERSION, 'config': {'CLOCK_FREQ': 144000000}}))
        for ext in ('hex', 'elf'):
            (self.output / ('klipper.' + ext)).write_text('fixture')

    def check(self, board='mainboard', version=VERSION):
        CHECKER.check(self.output, self.config, board, version)

    def test_both_boards(self):
        for board in ('mainboard', 'eboard'):
            with self.subTest(board=board):
                self.fixture(board)
                self.check(board)

    def test_mainboard_image_rejected_for_toolhead(self):
        self.fixture('mainboard')
        with self.assertRaisesRegex(ValueError, 'N32G455xC'):
            self.check('eboard')

    def test_wrong_host_version(self):
        self.fixture('mainboard')
        with self.assertRaisesRegex(ValueError, 'does not match host'):
            self.check(version='different-source-pin')

    def test_unsafe_board_settings(self):
        for old, new, key in (
            ('CONFIG_CLOCK_FREQ=144000000', 'CONFIG_CLOCK_FREQ=128000000', 'CLOCK_FREQ'),
            ('CONFIG_SERIAL_BAUD=230400', 'CONFIG_SERIAL_BAUD=115200', 'SERIAL_BAUD'),
            ('CONFIG_INITIAL_PINS="!PB9"', 'CONFIG_INITIAL_PINS="PB9"', 'INITIAL_PINS'),
        ):
            with self.subTest(key=key):
                self.fixture('mainboard')
                self.config.write_text(self.config.read_text().replace(old, new))
                with self.assertRaisesRegex(ValueError, key):
                    self.check()

    def test_toolhead_overflow(self):
        self.fixture('eboard')
        (self.output / 'klipper.bin').write_bytes(bytes(0x10001))
        with self.assertRaisesRegex(ValueError, 'exceeds application flash'):
            self.check('eboard')

    def test_toolhead_reset_into_bootloader(self):
        self.fixture('eboard')
        binary = self.output / 'klipper.bin'
        binary.write_bytes(struct.pack('<II', 0x20020000, 0x08000081) + bytes(248))
        with self.assertRaisesRegex(ValueError, 'reset vector'):
            self.check('eboard')

    def test_stack_outside_ram(self):
        self.fixture('mainboard')
        binary = self.output / 'klipper.bin'
        binary.write_bytes(struct.pack('<II', 0x20030000, 0x08000081) + bytes(248))
        with self.assertRaisesRegex(ValueError, 'stack pointer'):
            self.check()


if __name__ == '__main__':
    unittest.main()
