#!/usr/bin/env python3
"""Reproduce the vendor boot0 checksum tool's deterministic packing algorithm."""
import argparse
import struct
from pathlib import Path


def vendor_random_words(count):
    # glibc TYPE_3 random(), default seed 1, degree 31 and separation 3.
    # The original host tool calls rand() without srand(), once per output u32.
    state = [1]
    for _ in range(1, 31):
        state.append((16807 * state[-1]) % 2147483647)
    state.extend(state[:3])
    for index in range(34, 344 + count):
        state.append((state[index - 31] + state[index - 3]) & 0xffffffff)
        if index >= 344:
            yield state[-1] >> 1


def pack(raw):
    if len(raw) < 512 or raw[4:12] != b'eGON.BT0':
        raise ValueError('expected a complete source-built eGON.BT0 raw image')
    alignment = struct.unpack_from('<I', raw, 16)[0]
    if alignment not in (0x2000, 0x4000):
        raise ValueError('unexpected boot0 header alignment')
    length = (len(raw) + alignment - 1) & -alignment
    result = bytearray().join(struct.pack('<I', value)
                              for value in vendor_random_words(length // 4))
    result[:len(raw)] = raw
    struct.pack_into('<I', result, 16, length)
    struct.pack_into('<I', result, 12, 0x5f0a6c39)
    checksum = sum(value[0] for value in struct.iter_unpack('<I', result))
    struct.pack_into('<I', result, 12, checksum & 0xffffffff)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('raw_image', type=Path)
    parser.add_argument('output_image', type=Path)
    args = parser.parse_args()
    packed = pack(args.raw_image.read_bytes())
    with args.output_image.open('xb') as output:
        output.write(packed)


if __name__ == '__main__':
    main()
