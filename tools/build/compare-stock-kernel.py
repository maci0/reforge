#!/usr/bin/env python3
"""Read-only comparison of the AD5M stock ARM32 kernel Image and a source build."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct


IMAGE_BASE = 0xC0008000
SYMBOL_COUNT = 72471
SYMBOL_TYPES = frozenset('BDRTVWbdrt')
BUILD_ID_HEADER = struct.pack('<III', 4, 20, 3) + b'GNU\0'
PRIVATE_UID = re.compile(r'\.[0-9]+$')
SAMPLE_LIMIT = 32


def unique_offset(data, signature, label):
    offset = data.find(signature)
    if offset < 0 or data.find(signature, offset + 1) >= 0:
        raise ValueError(f'expected exactly one {label}')
    if offset % 4:
        raise ValueError(f'unaligned {label}')
    return offset


def decode_kallsyms(data):
    """Validate the contiguous relative-offset, names, markers and token tables."""
    base_offset = unique_offset(data, struct.pack('<II', IMAGE_BASE, SYMBOL_COUNT),
                                'stock kallsyms base/count signature')
    offsets_start = base_offset - SYMBOL_COUNT * 4
    if offsets_start < 0:
        raise ValueError('kallsyms offsets extend before the Image')
    names_start = base_offset + 8
    cursor = names_start
    compressed = []
    expected_markers = []
    for index in range(SYMBOL_COUNT):
        if index % 256 == 0:
            expected_markers.append(cursor - names_start)
        if cursor >= len(data):
            raise ValueError('truncated kallsyms name length')
        size = data[cursor]
        cursor += 1
        if not size or cursor + size > len(data):
            raise ValueError('empty or truncated compressed kallsyms name')
        compressed.append(data[cursor:cursor + size])
        cursor += size
    names_end = cursor
    markers_start = (cursor + 3) & ~3
    tokens_start = markers_start + len(expected_markers) * 4
    if tokens_start > len(data):
        raise ValueError('truncated kallsyms marker table')
    if any(data[names_end:markers_start]):
        raise ValueError('nonzero kallsyms name alignment bytes')
    markers = list(struct.unpack_from(f'<{len(expected_markers)}I', data, markers_start))
    if markers != expected_markers:
        raise ValueError('kallsyms markers do not identify every 256th name')
    cursor = tokens_start
    tokens = []
    token_offsets = []
    for _ in range(256):
        token_offsets.append(cursor - tokens_start)
        end = data.find(b'\0', cursor, min(cursor + 193, len(data)))
        if end < 0:
            raise ValueError('unterminated or oversized kallsyms token')
        token = data[cursor:end]
        if any(value < 32 or value > 126 for value in token):
            raise ValueError('non-ASCII kallsyms token')
        tokens.append(token.decode('ascii'))
        cursor = end + 1
    tokens_end = cursor
    index_start = (cursor + 1) & ~1
    end = index_start + 512
    if end > len(data):
        raise ValueError('truncated kallsyms token index')
    if any(data[tokens_end:index_start]):
        raise ValueError('nonzero kallsyms token alignment byte')
    if list(struct.unpack_from('<256H', data, index_start)) != token_offsets:
        raise ValueError('kallsyms token index does not match token boundaries')
    symbols = []
    previous_address = IMAGE_BASE
    for index, encoded in enumerate(compressed):
        name = ''.join(tokens[value] for value in encoded)
        if (not 2 <= len(name) <= 192 or name[0] not in SYMBOL_TYPES
                or any(not 33 <= ord(c) <= 126 for c in name[1:])):
            raise ValueError(f'invalid expanded kallsyms symbol {index}')
        address = IMAGE_BASE + struct.unpack_from('<I', data, offsets_start + index * 4)[0]
        if address > 0xFFFFFFFF or address < previous_address:
            raise ValueError('kallsyms addresses overflow ARM32 or are not sorted')
        previous_address = address
        symbols.append((address, name[0], name[1:]))
    if (IMAGE_BASE, 'T', '_text') not in symbols:
        raise ValueError('missing stock _text anchor')
    layout = {
        'offsets_start': offsets_start, 'relative_base_offset': base_offset,
        'num_syms_offset': base_offset + 4, 'names_start': names_start,
        'markers_start': markers_start, 'tokens_start': tokens_start,
        'index_start': index_start, 'end': end,
    }
    return {'layout': layout, 'symbols': symbols, 'validated_zero_alignment': {
        'names_end': names_end, 'names_padding_size': markers_start - names_end,
        'tokens_end': tokens_end, 'tokens_padding_size': index_start - tokens_end,
    }}


def inspect(data):
    kallsyms = decode_kallsyms(data)
    note = unique_offset(data, BUILD_ID_HEADER, 'GNU SHA1 build-id note')
    start = note + len(BUILD_ID_HEADER)
    end = start + 20
    if end > len(data):
        raise ValueError('truncated GNU build-id descriptor')
    layout = kallsyms['layout']
    if note < layout['end'] and end > layout['offsets_start']:
        raise ValueError('GNU build-id note overlaps kallsyms')
    return {**kallsyms, 'build_id': data[start:end].hex(),
            'build_id_layout': {'note_start': note, 'descriptor_start': start,
                                'descriptor_end': end}}


def byte_differences(left, right, excluded=()):
    count = 0
    first = None
    samples = []
    ranges = iter(sorted(excluded))
    current = next(ranges, None)
    for offset in range(max(len(left), len(right))):
        while current and offset >= current[1]:
            current = next(ranges, None)
        if current and current[0] <= offset < current[1]:
            continue
        a = left[offset] if offset < len(left) else None
        b = right[offset] if offset < len(right) else None
        if a != b:
            count += 1
            if first is None:
                first = offset
            if len(samples) < SAMPLE_LIMIT:
                samples.append({'offset': offset, 'stock': a, 'candidate': b})
    return {'count': count, 'first_offset': first, 'samples': samples}


def normalized_name(symbol):
    return PRIVATE_UID.sub('', symbol[2]) if symbol[1].islower() else symbol[2]


def compare(stock_path, candidate_path):
    paths = {'stock': Path(stock_path), 'candidate': Path(candidate_path)}
    data = {key: path.read_bytes() for key, path in paths.items()}
    report = {
        key: {'path': str(path), 'size': len(data[key]),
              'sha256': hashlib.sha256(data[key]).hexdigest()}
        for key, path in paths.items()
    }
    report.update({
        'full_file_equal': data['stock'] == data['candidate'], 'payload_equal': False,
        'full_file_byte_differences': byte_differences(data['stock'], data['candidate']),
        'equivalence_scope': 'exact static payload bytes and decoded kallsyms addresses/types/names',
        'permitted_metadata_differences': [
            'Only trailing .decimal UIDs in lowercase-type compiler-private symbol names.',
            'Only the 20-byte descriptor of the unique validated GNU build-id note.',
        ],
        'limitations': [
            'Payload equality is not full Image byte identity or historical lexical source identity.',
            'Static comparison does not establish runtime behavior on the printer.',
            'Inputs and their metadata are never rewritten.',
        ],
    })
    parsed = {}
    errors = {}
    for key, image in data.items():
        try:
            parsed[key] = inspect(image)
        except ValueError as error:
            errors[key] = str(error)
    report['validation_errors'] = errors
    if errors:
        return report
    stock, candidate = parsed['stock'], parsed['candidate']
    for key, image in parsed.items():
        report[key].update({name: image[name] for name in (
            'layout', 'validated_zero_alignment', 'build_id_layout', 'build_id')})
    layout_equal = stock['layout'] == candidate['layout']
    note_equal = stock['build_id_layout'] == candidate['build_id_layout']
    report.update({'symbol_count': SYMBOL_COUNT, 'metadata_layout_equal': layout_equal,
                   'build_id_layout_equal': note_equal})
    raw_count = normalized_count = uid_count = 0
    differences = []
    uids = []
    for index, (a, b) in enumerate(zip(stock['symbols'], candidate['symbols'])):
        if a == b:
            continue
        raw_count += 1
        item = {'index': index, 'stock': a, 'candidate': b}
        if a[:2] == b[:2] and normalized_name(a) == normalized_name(b):
            uid_count += 1
            if len(uids) < SAMPLE_LIMIT:
                uids.append(item)
        else:
            normalized_count += 1
            if len(differences) < SAMPLE_LIMIT:
                differences.append(item)
    report['symbol_differences'] = {
        'raw_count': raw_count, 'normalized_count': normalized_count,
        'permitted_private_uid_count': uid_count, 'samples': differences,
        'private_uid_samples': uids,
    }
    excluded = []
    if layout_equal and note_equal:
        layout = stock['layout']
        note = stock['build_id_layout']
        excluded = [(layout['offsets_start'], layout['end']),
                    (note['descriptor_start'], note['descriptor_end'])]
    outside = byte_differences(data['stock'], data['candidate'], excluded)
    report['outside_validated_metadata_byte_differences'] = outside
    report['payload_equal'] = (layout_equal and note_equal and not normalized_count
                               and not outside['count'])
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stock_image', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    inputs = (args.stock_image, args.candidate)
    if (args.report.resolve() in {path.resolve() for path in inputs}
            or args.report.exists() and any(path.exists() and args.report.samefile(path)
                                           for path in inputs)):
        parser.error('report must not overwrite either input Image')
    try:
        report = compare(*inputs)
    except (OSError, ValueError) as error:
        report = {'full_file_equal': False, 'payload_equal': False, 'error': str(error)}
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report['payload_equal'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
