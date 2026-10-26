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


def calculate(data):
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
    digest = hashlib.sha1(header)
    for index in range(elf['e_phnum']):
        offset = elf['e_phoff'] + index * 32
        digest.update(data[offset:offset + 32])
    for index, section in enumerate(elf.iter_sections()):
        offset = elf['e_shoff'] + index * 40
        header = bytearray(data[offset:offset + 40])
        struct.pack_into('<I', header, 16, 0)  # BFD zeros sh_offset.
        digest.update(header)
        # These table contents are not materialized in BFD's checksum pass.
        if section['sh_type'] == 'SHT_NOBITS' or section.name in {'.symtab', '.strtab', '.shstrtab'}:
            continue
        contents = bytearray(section.data())
        if section.name == note_section.name:
            offset = note['n_offset'] - section['sh_offset']
            # The entire generated GNU note is still zero in the hashed buffer.
            contents[offset:offset + 36] = bytes(36)
        digest.update(contents)
    computed = digest.hexdigest()
    return {'stored': note['n_desc'], 'computed': computed,
            'matches': computed == note['n_desc']}


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(f'usage: {sys.argv[0]} PRE_SORT_ELF')
    result = calculate(Path(sys.argv[1]).read_bytes())
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['matches'] else 1)
