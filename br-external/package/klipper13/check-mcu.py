#!/usr/bin/env python3
"""Reject MCU artifacts whose board, address, size or protocol identity is wrong."""
import json
from pathlib import Path
import struct
import sys


def check(output, config, board, version):
    values = dict(line.split('=', 1) for line in config.read_text().splitlines()
                  if line.startswith('CONFIG_') and '=' in line)
    variant, address = {'mainboard': ('E', 0x08000000),
                        'eboard': ('C', 0x08010000)}[board]
    expected = {'CONFIG_MACH_N32G455x' + variant: 'y',
                'CONFIG_CLOCK_FREQ': '144000000',
                'CONFIG_CLOCK_REF_FREQ': '12000000',
                'CONFIG_SERIAL_BAUD': '230400',
                'CONFIG_STM32_SERIAL_USART1': 'y',
                'CONFIG_INITIAL_PINS': '"!PB9"' if board == 'mainboard' else '""',
                'CONFIG_FLASHFORGE_LOADCELL': 'y' if board == 'mainboard' else None,
                'CONFIG_FLASHFORGE_TVOC': 'y' if board == 'mainboard' else None,
                'CONFIG_FLASH_APPLICATION_ADDRESS': hex(address)}
    for key, value in expected.items():
        actual = values.get(key)
        if key == 'CONFIG_FLASH_APPLICATION_ADDRESS' and actual is not None:
            actual = hex(int(actual, 0))
        if actual != value:
            raise ValueError(f'{board}: {key}={actual}, expected {value}')
    data = (output / 'klipper.bin').read_bytes()
    flash_end = 0x08000000 + int(values['CONFIG_FLASH_SIZE'], 0)
    if not 8 <= len(data) <= flash_end - address:
        raise ValueError(f'{board}: firmware size {len(data)} exceeds application flash')
    stack, reset = struct.unpack_from('<II', data)
    ram_start = int(values['CONFIG_RAM_START'], 0)
    ram_end = ram_start + int(values['CONFIG_RAM_SIZE'], 0)
    if not ram_start < stack <= ram_end or stack % 8:
        raise ValueError(f'{board}: invalid initial stack pointer {stack:#x}')
    if not reset & 1 or not address <= (reset & ~1) < address + len(data):
        raise ValueError(f'{board}: reset vector {reset:#x} is outside application')
    protocol = json.loads((output / 'klipper.dict').read_text())
    if protocol['version'] != version:
        raise ValueError(f'{board}: MCU version does not match host {version}')
    if protocol['config']['CLOCK_FREQ'] != 144000000:
        raise ValueError(f'{board}: protocol reports the wrong MCU clock')
    for ext in ('hex', 'elf'):
        if not (output / ('klipper.' + ext)).stat().st_size:
            raise ValueError(f'{board}: empty {ext} artifact')
    print(f'{board}: {len(data)} bytes, address {address:#x}, version {version}')


if __name__ == '__main__':
    check(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4])
