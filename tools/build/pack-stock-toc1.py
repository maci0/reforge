#!/usr/bin/env python3
"""Pack the AD5M's three-member, unencrypted sunxi-package TOC1 container."""
import argparse
from pathlib import Path
import struct


HEADER = struct.Struct('<16s12I')
ITEM = struct.Struct('<64s76I')
STAMP = 0x5f0a6c39


def align(length, boundary):
    return (length + boundary - 1) & -boundary


def pack(uboot, optee, dtb):
    payloads = (uboot, optee, dtb)
    if any(not payload for payload in payloads):
        raise ValueError('all three TOC1 payloads must be nonempty')
    offset = align(HEADER.size + 3 * ITEM.size, 2048)
    offsets = []
    for payload in payloads:
        offsets.append(offset)
        offset = align(offset + len(payload), 2048)
    length = align(offset, 16384)
    if length > 0xffffffff:
        raise ValueError('TOC1 length exceeds its 32-bit field')
    result = bytearray(length)
    HEADER.pack_into(result, 0, b'sunxi-package', 0x89119800, STAMP,
                     0, 0, 3, length, 0, 0, 0, 0, 0, 0x3b45494d)
    # private_toc.h: unencrypted binary, no explicit run address/index, reserved zero.
    for index, (name, payload, start) in enumerate(zip(
            (b'u-boot', b'optee', b'dtb'), payloads, offsets)):
        ITEM.pack_into(result, HEADER.size + index * ITEM.size, name,
                       start, len(payload), 0, 3, 0, 0, *([0] * 69), 0x3b454949)
        result[start:start + len(payload)] = payload
    checksum = sum(word[0] for word in struct.iter_unpack('<I', result)) & 0xffffffff
    struct.pack_into('<I', result, 20, checksum)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('uboot', type=Path)
    parser.add_argument('optee', type=Path)
    parser.add_argument('dtb', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    packed = pack(*(path.read_bytes() for path in (args.uboot, args.optee, args.dtb)))
    with args.output.open('xb') as output:
        output.write(packed)


if __name__ == '__main__':
    main()
