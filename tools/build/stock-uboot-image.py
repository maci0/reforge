#!/usr/bin/env python3
"""Recover control-DTB configuration and pack a source-built AD5M U-Boot image."""
from pathlib import Path
import struct
import sys

STAMP = 0x5F0A6C39
FDT_MAGIC = b'\xd0\x0d\xfe\xed'


def header(image):
    if len(image) < 0x600 or image[4:12] != b'uboot\0\0\0':
        raise ValueError('not an Allwinner U-Boot payload')
    alignment = struct.unpack_from('<I', image, 16)[0]
    if alignment != 0x4000:
        raise ValueError('expected the stock AD5M 16-KiB image alignment')
    return alignment


def checksum(image):
    if len(image) % 4:
        raise ValueError('checksum input must contain complete 32-bit words')
    stored = struct.unpack_from('<I', image, 12)[0]
    return (sum(x[0] for x in struct.iter_unpack('<I', image)) - stored + STAMP) & 0xFFFFFFFF


def validate_dtb(data):
    if len(data) < 56 or data[:4] != FDT_MAGIC:
        raise ValueError('invalid control-DTB header')
    _, total, structure, strings, reserve, version, compatible, _, names, tokens = struct.unpack_from('>10I', data)
    if (total != len(data) or version != 17 or compatible != 16
            or reserve != 40 or structure != 56 or tokens < 16 or tokens % 4
            or strings != structure + tokens or strings + names != total
            or data[reserve:structure] != bytes(16)
            or data[structure:structure + 8] != b'\0\0\0\x01\0\0\0\0'
            or data[strings - 4:strings] != b'\0\0\0\x09'):
        raise ValueError('unsupported or truncated AD5M control-DTB layout')


def reference_dtb(image):
    alignment = header(image)
    if (len(image) % alignment or struct.unpack_from('<II', image, 20) != (len(image), len(image))
            or checksum(image) != struct.unpack_from('<I', image, 12)[0]):
        raise ValueError('stock reference length or checksum is invalid')
    matches = []
    start = 0x600
    while (offset := image.find(FDT_MAGIC, start)) != -1:
        start = offset + 4
        if offset % 4 or offset + 40 > len(image):
            continue
        length = struct.unpack_from('>I', image, offset + 4)[0]
        if not 56 <= length <= len(image) - offset:
            continue
        dtb = image[offset:offset + length]
        try:
            validate_dtb(dtb)
        except ValueError:
            continue
        if image[offset + length:] == b'\xff' * (len(image) - offset - length):
            matches.append(dtb)
    if len(matches) != 1:
        raise ValueError('expected one appended stock control DTB followed by 0xff fill')
    return matches[0]


def pack(core, dtb, reference):
    alignment = header(core)
    original_dtb = reference_dtb(reference)
    validate_dtb(dtb)
    if dtb != original_dtb:
        raise ValueError('source-compiled control DTB does not match the stock configuration')
    content_size = len(core) + len(dtb)
    packed_size = (content_size + alignment - 1) // alignment * alignment
    if packed_size != len(reference):
        raise ValueError(f'source payload needs {packed_size} bytes; stock span is {len(reference)}; refusing to truncate or force the size')
    image = bytearray(core + dtb + b'\xff' * (packed_size - content_size))
    struct.pack_into('<II', image, 20, packed_size, packed_size)
    struct.pack_into('<I', image, 12, checksum(image))
    return bytes(image)


def read(path):
    if path.stat().st_size > 0x400000:
        raise ValueError('AD5M U-Boot input exceeds its four-MiB boot slot')
    return path.read_bytes()


if __name__ == '__main__':
    try:
        operation = sys.argv[1]
        if operation == 'extract-dtb' and len(sys.argv) == 4:
            result = reference_dtb(read(Path(sys.argv[2])))
        elif operation == 'pack' and len(sys.argv) == 6:
            result = pack(*(read(Path(p)) for p in sys.argv[2:5]))
        else:
            raise ValueError('usage: stock-uboot-image.py extract-dtb REFERENCE OUTPUT | pack CORE COMPILED_DTB REFERENCE OUTPUT')
        with Path(sys.argv[-1]).open('xb') as stream:
            stream.write(result)
    except (IndexError, OSError, ValueError) as exc:
        raise SystemExit(str(exc))
