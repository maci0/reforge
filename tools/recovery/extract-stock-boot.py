#!/usr/bin/env python3
"""Extract AD5M primary bootloader reference bytes; never source-build outputs."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import struct

BOOT0_OFFSET = 0x2000
TOC_OFFSET = 0xC00000
CHECKSUM_STAMP = 0x5F0A6C39
TOC_MAGIC = 0x89119800
TOC_END = 0x3B45494D
ITEM_END = 0x3B454949
ITEM_SIZE = 368
MEMBERS = ('u-boot', 'optee', 'dtb')


def read_at(stream, offset, size):
    stream.seek(offset)
    data = stream.read(size)
    if len(data) != size:
        raise ValueError(f'truncated image at offset {offset:#x}: need {size} bytes')
    return data


def check_sum(data, offset, label):
    stored = struct.unpack_from('<I', data, offset)[0]
    computed = (sum(word[0] for word in struct.iter_unpack('<I', data))
                - stored + CHECKSUM_STAMP) & 0xFFFFFFFF
    if stored != computed:
        raise ValueError(f'{label}: invalid additive checksum')
    return f'{stored:#010x}'


def extract(source, destination):
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(f'destination already exists: {destination}')
    with source.open('rb') as stream:
        compressed = stream.read(2) == b'\x1f\x8b'
    opener = gzip.open if compressed else open
    with opener(source, 'rb') as stream:
        header = read_at(stream, BOOT0_OFFSET, 48)
        if header[4:12] != b'eGON.BT0':
            raise ValueError('boot0: missing eGON.BT0 header at 0x2000')
        length, header_size = struct.unpack_from('<II', header, 16)
        # The primary boot0 must end before the backup slot at 0x20000.
        if header_size != 48 or not 48 <= length <= 0x1E000 or length % 4:
            raise ValueError('boot0: invalid length or header size')
        boot0 = read_at(stream, BOOT0_OFFSET, length)
        boot0_sum = check_sum(boot0, 12, 'boot0')

        header = read_at(stream, TOC_OFFSET, 64)
        magic = struct.unpack_from('<I', header, 16)[0]
        count, length = struct.unpack_from('<II', header, 32)
        if (header[:16] != b'sunxi-package\0\0\0' or magic != TOC_MAGIC
                or struct.unpack_from('<I', header, 60)[0] != TOC_END):
            raise ValueError('TOC1: invalid primary header at 0xc00000')
        table_end = 64 + len(MEMBERS) * ITEM_SIZE
        # Keep the primary package within its four-MiB slot, before the backup.
        if count != len(MEMBERS) or not table_end <= length <= 0x400000 or length % 4:
            raise ValueError('TOC1: invalid item count or package length')
        toc = read_at(stream, TOC_OFFSET, length)
        toc_sum = check_sum(toc, 20, 'TOC1')

    artifacts = {'boot0.bin': (boot0, BOOT0_OFFSET),
                 'sunxi-package.bin': (toc, TOC_OFFSET)}
    ranges = []
    for index in range(count):
        base = 64 + index * ITEM_SIZE
        name = toc[base:base + 64].split(b'\0', 1)[0].decode('ascii')
        offset, size, encrypted, kind = struct.unpack_from('<4I', toc, base + 64)
        if (name not in MEMBERS or name + '.bin' in artifacts or encrypted != 0
                or kind != 3 or struct.unpack_from('<I', toc, base + 364)[0] != ITEM_END):
            raise ValueError('TOC1: unexpected, duplicate or unsupported member')
        if size == 0 or offset < table_end or offset > length or size > length - offset:
            raise ValueError(f'TOC1: {name} range is outside package data')
        if any(offset < end and start < offset + size for start, end in ranges):
            raise ValueError(f'TOC1: {name} overlaps another member')
        ranges.append((offset, offset + size))
        artifacts[name + '.bin'] = (toc[offset:offset + size], TOC_OFFSET + offset)

    manifest = {
        'purpose': 'reference-only artifact extraction; these bytes are not source-build outputs',
        'scope': 'Primary boot slots only; full-image and gzip-trailer integrity are not checked.',
        'source': {'path': str(source.resolve()), 'size_bytes': source.stat().st_size,
                   'encoding': 'gzip' if compressed else 'plain',
                   'sha256': None,
                   'hash_note': 'Full input not hashed; only the required boot prefix was read.'},
        'checksums': {'boot0_additive': boot0_sum, 'toc1_additive': toc_sum},
        'artifacts': {name: {'offset': offset, 'length': len(data),
                              'sha256': hashlib.sha256(data).hexdigest()}
                      for name, (data, offset) in artifacts.items()},
    }
    destination.mkdir(mode=0o700, parents=True)
    for name, (data, _) in artifacts.items():
        with (destination / name).open('xb') as stream:
            stream.write(data)
    with (destination / 'manifest.json').open('x') as stream:
        json.dump(manifest, stream, indent=2)
        stream.write('\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path, help='plain or gzip-compressed full eMMC image')
    parser.add_argument('output', type=Path, help='new directory for reference artifacts')
    args = parser.parse_args()
    try:
        extract(args.image, args.output)
    except (OSError, EOFError, ValueError) as exc:
        parser.exit(1, f'{exc}\n')
    print(args.output / 'manifest.json')


if __name__ == '__main__':
    main()
