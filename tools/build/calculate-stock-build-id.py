#!/usr/bin/env python3
"""Read-only GNU ld 2.25 build-ID model for this stock ARM32 link pipeline.

Supply the ELF before sortextable/objcopy, not the delivered raw Image.
This models the observed BFD write-time buffers, not every GNU ld version.
"""

import hashlib
from io import BytesIO
import json
from pathlib import Path
import struct
import sys

from elftools.elf.elffile import ELFFile


def calculate(data, include_headers=False):
    elf = ELFFile(BytesIO(data))
    if not (elf.elfclass == 32 and elf.little_endian and elf['e_machine'] == 'EM_ARM'
            and elf['e_ehsize'] == 52 and elf['e_shentsize'] == 40
            and (not elf['e_phnum'] or elf['e_phentsize'] == 32)):
        raise ValueError('expected the stock pipeline\'s little-endian ARM32 ELF layout')
    notes = [(section, note) for section in elf.iter_sections()
             if section['sh_type'] == 'SHT_NOTE' for note in section.iter_notes()
             if note['n_name'] == 'GNU' and note['n_type'] == 'NT_GNU_BUILD_ID']
    if len(notes) != 1 or notes[0][1]['n_namesz'] != 4 or notes[0][1]['n_descsz'] != 20:
        raise ValueError('expected exactly one 20-byte GNU build-ID note')
    note_section, note = notes[0]
    header = bytearray(data[:52])
    struct.pack_into('<II', header, 28, 0, 0)  # BFD zeros e_phoff and e_shoff.
    fields = {key: value for key, value in elf.header.items() if key != 'e_ident'}
    fields.update(e_ident=data[:16].hex(), e_phoff=0, e_shoff=0)
    headers = {'elf': {'fields': fields, 'hashed_bytes': header.hex()},
               'program': [], 'section': []}
    digest = hashlib.sha1(header)
    for index in range(elf['e_phnum']):
        offset = elf['e_phoff'] + index * 32
        digest.update(data[offset:offset + 32])
        if include_headers:
            headers['program'].append({'index': index,
                'fields': dict(elf.get_segment(index).header),
                'hashed_bytes': data[offset:offset + 32].hex()})
    for index, section in enumerate(elf.iter_sections()):
        offset = elf['e_shoff'] + index * 40
        header = bytearray(data[offset:offset + 40])
        struct.pack_into('<I', header, 16, 0)  # BFD zeros sh_offset.
        digest.update(header)
        skipped = (section['sh_type'] == 'SHT_NOBITS'
                   or section.name in {'.symtab', '.strtab', '.shstrtab'})
        entry = {'index': index, 'name': section.name,
                 'fields': dict(section.header, sh_offset=0),
                 'hashed_bytes': header.hex(), 'contents_hashed': not skipped}
        if include_headers:
            headers['section'].append(entry)
        # These table contents are not materialized in BFD's checksum pass.
        if skipped:
            continue
        contents = bytearray(section.data())
        if section.name == note_section.name:
            offset = note['n_offset'] - section['sh_offset']
            # The entire generated GNU note is still zero in the hashed buffer.
            contents[offset:offset + 36] = bytes(36)
        digest.update(contents)
        if include_headers:
            entry['hashed_contents_sha256'] = hashlib.sha256(contents).hexdigest()
    computed = digest.hexdigest()
    result = {'stored': note['n_desc'], 'computed': computed,
              'matches': computed == note['n_desc']}
    if include_headers:
        result['headers'] = headers
    return result


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != '--headers'):
        raise SystemExit(f'usage: {sys.argv[0]} PRE_SORT_ELF [--headers]')
    result = calculate(Path(sys.argv[1]).read_bytes(), include_headers=len(sys.argv) == 3)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['matches'] else 1)
