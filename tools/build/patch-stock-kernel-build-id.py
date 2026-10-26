#!/usr/bin/env python3
"""Apply the explicitly authorized 20-byte stock kernel metadata patch."""
import argparse
import hashlib
import json
from pathlib import Path

IMAGE_BYTES = 12970156
ID_OFFSET = 0xACC154
STOCK_ID = bytes.fromhex('07002ca89d308edcf17b1bdca56d38bc46972263')
STOCK_SHA256 = '902f44fe517aedd9424fa14adbf4f7c6212f372cfed10b19d479044a53111fa6'
NOTE_HEADER = bytes.fromhex('040000001400000003000000474e5500')


def patch(image):
    if len(image) != IMAGE_BYTES:
        raise ValueError('wrong stock kernel image size')
    if image[ID_OFFSET - 16:ID_OFFSET] != NOTE_HEADER:
        raise ValueError('expected GNU build-ID note is missing')
    result = image[:ID_OFFSET] + STOCK_ID + image[ID_OFFSET + 20:]
    if hashlib.sha256(result).hexdigest() != STOCK_SHA256:
        raise ValueError('kernel differs from stock outside the permitted build-ID field')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path, help='source-built raw Image; left unchanged')
    parser.add_argument('output', type=Path, help='new file for the patched Image')
    args = parser.parse_args()
    try:
        original = args.input.read_bytes()
        result = patch(original)
        with args.output.open('xb') as output:
            output.write(result)
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')
    print(json.dumps({'operation': 'explicit GNU build-ID metadata patch',
                      'input_sha256': hashlib.sha256(original).hexdigest(),
                      'old_build_id': original[ID_OFFSET:ID_OFFSET + 20].hex(),
                      'new_build_id': STOCK_ID.hex(),
                      'different_bytes': sum(a != b for a, b in zip(original, result)),
                      'output_sha256': STOCK_SHA256,
                      'output_bytes': len(result)}, indent=2))


if __name__ == '__main__':
    main()
