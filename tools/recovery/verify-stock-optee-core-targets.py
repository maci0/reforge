#!/usr/bin/env python3
"""Read-only relocation-target audit of the recorded near-matching core sections."""
import hashlib
import io
import json
from pathlib import Path
import struct
import sys
from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB
from elftools.elf.elffile import ELFFile

ROOT = Path(__file__).resolve().parents[2]
BASE = 0x41b00000


def masked(section, elf):
    data = bytearray(section.data())
    relocations = elf.get_section_by_name('.rel' + section.name)
    if relocations:
        for rel in relocations.iter_relocations():
            assert rel['r_info_type'] in (2, 3, 10, 28, 29, 30, 42, 43, 44, 47, 48)
            off = rel['r_offset']
            assert off + 4 <= len(data)
            data[off:off + 4] = bytes(4)
    return data


def audit(build, stock):
    proof = json.loads((ROOT / 'docs/board-notes/stock-optee-core-immediates-proof.json').read_text())
    assert hashlib.sha256(stock).hexdigest() == proof['stock_sha256']
    objects = {}
    definitions = {}
    for path in (build / 'build/core').rglob('*.o'):
        if path.name in ('all_objs.o', 'unpaged.o', 'init.o'):
            continue
        elf = ELFFile(io.BytesIO(path.read_bytes()))
        objects[path] = elf
        for section in elf.iter_sections():
            if section.name.startswith('.text.'):
                definitions.setdefault(section.name[6:], []).append((path, elf, section))
    cs = Cs(CS_ARCH_ARM, CS_MODE_THUMB)
    results = []
    for routine in proof['routines']:
        path = build / 'build' / routine['source_object']
        elf = objects[path]
        section = elf.get_section_by_name(routine['section'])
        rels = elf.get_section_by_name('.rel' + section.name)
        symbols = elf.get_section(rels['sh_link'])
        original = int(routine['stock_offset'], 16)
        for rel in rels.iter_relocations():
            off = rel['r_offset']
            symbol = symbols.get_symbol(rel['r_info_sym'])
            row = {'caller': routine['section'][6:], 'offset': off, 'symbol': symbol.name}
            if rel['r_info_type'] == 10:
                instruction = next(cs.disasm(stock[original + off:original + off + 4], BASE + original + off))
                assert instruction.mnemonic in ('bl', 'blx')
                target = int(instruction.op_str.removeprefix('#'), 16) & ~1
                row['stock_target'] = hex(target)
                candidates = definitions.get(symbol.name, [])
                local = [entry for entry in candidates if entry[0] == path]
                candidates = local or candidates
                if len(candidates) == 1:
                    _, callee_elf, callee = candidates[0]
                    expected = masked(callee, callee_elf)
                    actual = bytearray(stock[target - BASE:target - BASE + len(expected)])
                    callee_rels = callee_elf.get_section_by_name('.rel' + callee.name)
                    if callee_rels:
                        for item in callee_rels.iter_relocations():
                            pos = item['r_offset']; actual[pos:pos + 4] = bytes(4)
                    row['callee_bytes'] = len(expected)
                    row['different_nonrelocation_bytes'] = sum(a != b for a, b in zip(expected, actual)) + abs(len(expected) - len(actual))
                    row['status'] = 'callee-body-match' if expected == actual else 'callee-body-differs'
                else:
                    row['status'] = 'callee-definition-ambiguous-or-missing'
            elif rel['r_info_type'] == 2:
                target = struct.unpack_from('<I', stock, original + off)[0]
                row['stock_target'] = hex(target)
                index = symbol['st_shndx']
                if isinstance(index, int):
                    data = elf.get_section(index)
                    addend = struct.unpack_from('<I', section.data(), off)[0]
                    pos = symbol['st_value'] + addend
                    if data.name.startswith('.rodata') and pos < data['sh_size']:
                        value = data.data()[pos:].split(b'\0', 1)[0] + b'\0'
                        if value != b'\0' and all(32 <= c < 127 or c in (0, 9, 10, 13) for c in value):
                            row['status'] = 'string-match' if stock[target - BASE:target - BASE + len(value)] == value else 'string-differs'
                            row['source_string'] = value[:-1].decode()
                row.setdefault('status', 'data-target-unresolved')
            else:
                raise AssertionError('Unexpected caller relocation')
            results.append(row)
    return {'source_build': str(build), 'stock_sha256': hashlib.sha256(stock).hexdigest(),
            'scope': 'Direct callee bodies and string contents only; callee relocation targets and other data remain unproven',
            'checks': results}


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: verify-stock-optee-core-targets.py SOURCE_BUILD STOCK_REFERENCE')
    print(json.dumps(audit(Path(sys.argv[1]), Path(sys.argv[2]).read_bytes()), indent=2))
