#!/usr/bin/env python3
"""Generate legacy ARM uImage metadata and compare wrappers to the stock reference."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

MAGIC = 0x27051956
TIMESTAMP = 1692776025
LOAD = 0x40008000
NAME = b'Linux-5.4.61'.ljust(32, b'\0')
REFERENCE_SHA256 = '13c17296c9ed34cff1c355dc717ab76803410bd872a495bdefaca07cdaf89c79'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def zimage_bounds(data):
    if len(data) < 48:
        raise ValueError('truncated ARM zImage header')
    magic, start, end = struct.unpack_from('<III', data, 36)
    if magic != 0x016F2818 or start != 0 or end != len(data):
        raise ValueError('unexpected ARM zImage header or declared size')


def parse(data):
    if len(data) < 64:
        raise ValueError('truncated legacy uImage header')
    fields = struct.unpack('>7I4B32s', data[:64])
    magic, hcrc, timestamp, size, load, entry, dcrc, os_id, arch, kind, compression, name = fields
    if magic != MAGIC or size != len(data) - 64:
        raise ValueError('invalid legacy uImage magic or payload length')
    header = bytearray(data[:64])
    header[4:8] = bytes(4)
    if zlib.crc32(header) != hcrc:
        raise ValueError('legacy uImage header CRC mismatch')
    if zlib.crc32(data[64:]) != dcrc:
        raise ValueError('legacy uImage data CRC mismatch')
    if (timestamp, load, entry, os_id, arch, kind, compression, name) != (TIMESTAMP, LOAD, LOAD, 5, 2, 2, 0, NAME):
        raise ValueError('legacy uImage metadata differs from the original board profile')
    zimage_bounds(data[64:])
    return {'timestamp': timestamp, 'payload_size': size, 'load': load, 'entry': entry,
            'os': os_id, 'architecture': arch, 'type': kind, 'compression': compression,
            'name': name.rstrip(b'\0').decode('ascii'), 'header_crc32': hcrc, 'payload_crc32': dcrc}


def pack(source, output):
    payload = Path(source).read_bytes()
    zimage_bounds(payload)
    fields = (MAGIC, 0, TIMESTAMP, len(payload), LOAD, LOAD, zlib.crc32(payload), 5, 2, 2, 0, NAME)
    header = bytearray(struct.pack('>7I4B32s', *fields))
    struct.pack_into('>I', header, 4, zlib.crc32(header))
    data = bytes(header) + payload
    parse(data)
    with Path(output).open('xb') as stream:
        stream.write(data)


def compare(reference, candidate, output):
    report = {'full_file_equal': False}
    try:
        original, built = Path(reference).read_bytes(), Path(candidate).read_bytes()
        report.update(reference_sha256=digest(original), candidate_sha256=digest(built),
                      reference_size=len(original), candidate_size=len(built))
        if digest(original) != REFERENCE_SHA256:
            raise ValueError('original uImage SHA-256 does not match the board reference')
        report['reference_header'], report['candidate_header'] = parse(original), parse(built)
        report['zImage_full_file_equal'] = built[64:] == original[64:]
        report['full_file_equal'] = built == original
        report['differing_bytes'] = sum(a != b for a, b in zip(original, built)) + abs(len(original) - len(built))
        payload = built[64:]
        start = payload.find(b'\x1f\x8b\x08')
        if start < 0:
            raise ValueError('gzip stream missing from zImage')
        decoder = zlib.decompressobj(31)
        raw = decoder.decompress(payload[start:])
        if not decoder.eof:
            raise ValueError('incomplete zImage gzip stream')
        report.update(raw_Image_sha256=digest(raw), gzip_offset=start,
                      gzip_size=len(payload)-start-len(decoder.unused_data))
    except (OSError, ValueError, zlib.error) as error:
        report['error'] = str(error)
        report['full_file_equal'] = False
    with Path(output).open('x') as stream:
        stream.write(json.dumps(report, indent=2) + '\n')
    return 0 if report['full_file_equal'] else 1


def main(argv):
    if len(argv) == 4 and argv[1] == 'pack':
        pack(argv[2], argv[3])
        return 0
    if len(argv) == 5 and argv[1] == 'compare':
        return compare(argv[2], argv[3], argv[4])
    raise ValueError('usage: stock-kernel-wrappers.py pack ZIMAGE OUTPUT | compare STOCK_UIMAGE CANDIDATE_UIMAGE REPORT.json')


if __name__ == '__main__':
    try:
        raise SystemExit(main(sys.argv))
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
