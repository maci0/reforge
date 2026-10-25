#!/usr/bin/env python3
"""Compare source-built ARM kernel modules without hiding provenance differences."""
import argparse
from collections import defaultdict
import hashlib
from io import BytesIO
import json
from pathlib import Path

from elftools.common.exceptions import ELFError
from elftools.elf.elffile import ELFFile

PROVENANCE_SECTIONS = {'.modinfo', '.note.gnu.build-id'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inspect(path):
    data = Path(path).read_bytes()
    elf = ELFFile(BytesIO(data))
    abi = {
        'machine': elf['e_machine'], 'type': elf['e_type'],
        'class': elf.elfclass, 'little_endian': elf.little_endian,
        'flags': elf['e_flags'], 'osabi': elf['e_ident']['EI_OSABI'],
        'abi_version': elf['e_ident']['EI_ABIVERSION'],
    }
    if (abi['machine'], abi['type'], abi['class'], abi['little_endian']) != (
            'EM_ARM', 'ET_REL', 32, True):
        raise ValueError(f'{path}: expected a little-endian ARM32 ET_REL module')
    sections = {}
    runtime = {}
    relocations = defaultdict(list)
    metadata = {}
    for index, section in enumerate(elf.iter_sections()):
        if index == 0 and section['sh_type'] == 'SHT_NULL':
            continue
        if not section.name:
            raise ValueError(f'{path}: unnamed section at index {index}')
        if section.name in sections:
            raise ValueError(f'{path}: duplicate section name {section.name!r}')
        nobits = section['sh_type'] == 'SHT_NOBITS'
        description = {
            'type': section['sh_type'], 'flags': section['sh_flags'],
            'size': section['sh_size'], 'alignment': section['sh_addralign'],
            'entry_size': section['sh_entsize'], 'address': section['sh_addr'],
            'sha256': None if nobits else digest(section.data()),
        }
        sections[section.name] = description
        if section.name in PROVENANCE_SECTIONS:
            expected_type = 'SHT_PROGBITS' if section.name == '.modinfo' else 'SHT_NOTE'
            if (section['sh_type'] != expected_type or not section['sh_flags'] & 2
                    or section['sh_flags'] & 4):
                raise ValueError(f'{path}: malformed or executable metadata {section.name}')
            shape = {key: value for key, value in description.items() if key != 'sha256'}
            if section.name == '.modinfo':
                payload = section.data()
                if not payload or not payload.endswith(b'\0'):
                    raise ValueError(f'{path}: unterminated .modinfo')
                entries = payload.decode('utf-8').split('\0')[:-1]
                if any(entry and ('=' not in entry or not entry.split('=', 1)[0])
                       for entry in entries):
                    raise ValueError(f'{path}: malformed .modinfo entry')
                shape.pop('size')
                metadata[section.name] = {
                    'shape': shape,
                    'entries': [entry for entry in entries if not entry.startswith('srcversion=')],
                }
            else:
                notes = list(section.iter_notes())
                if (len(notes) != 1 or notes[0]['n_name'] != 'GNU'
                        or notes[0]['n_type'] != 'NT_GNU_BUILD_ID'
                        or not notes[0]['n_descsz'] or notes[0]['n_size'] != section['sh_size']):
                    raise ValueError(f'{path}: malformed GNU build-id note')
                note = notes[0]
                descriptor_start = 12 + ((note['n_namesz'] + 3) & ~3)
                descriptor_end = descriptor_start + note['n_descsz']
                shape['note_envelope_sha256'] = digest(
                    section.data()[:descriptor_start] + section.data()[descriptor_end:])
                shape['descriptor_size'] = note['n_descsz']
                metadata[section.name] = shape
        elif section['sh_flags'] & 2:
            runtime[section.name] = description
        if section['sh_type'] not in ('SHT_REL', 'SHT_RELA'):
            continue
        target = elf.get_section(section['sh_info'])
        if not target['sh_flags'] & 2:
            continue
        symbols = elf.get_section(section['sh_link'])
        for relocation in section.iter_relocations():
            if relocation['r_offset'] >= target['sh_size']:
                raise ValueError(f'{path}: relocation outside {target.name}')
            symbol = symbols.get_symbol(relocation['r_info_sym'])
            index = symbol['st_shndx']
            symbol_section = elf.get_section(index).name if isinstance(index, int) else index
            relocations[target.name].append({
                'offset': relocation['r_offset'], 'type': relocation['r_info_type'],
                'addend': relocation['r_addend'] if section.is_RELA() else None,
                'symbol': {
                    # Compiler-local numeric suffixes do not identify runtime targets.
                    'name': symbol.name if symbol['st_info']['bind'] != 'STB_LOCAL'
                    or index == 'SHN_UNDEF' else None,
                    'section': symbol_section, 'value': symbol['st_value'],
                    'size': symbol['st_size'], 'type': symbol['st_info']['type'],
                    'binding': symbol['st_info']['bind'],
                    'visibility': symbol['st_other']['visibility'],
                },
            })
    for entries in relocations.values():
        entries.sort(key=lambda entry: json.dumps(entry, sort_keys=True))
    return {
        'path': str(Path(path).resolve()), 'size': len(data), 'sha256': digest(data),
        'abi': abi, 'sections': sections, 'runtime_sections': runtime,
        'allocated_target_relocations': dict(relocations), 'operational_metadata': metadata,
    }


def differences(stock, candidate):
    return [{'name': name, 'stock': stock.get(name), 'candidate': candidate.get(name)}
            for name in sorted(stock.keys() | candidate.keys())
            if stock.get(name) != candidate.get(name)]


def compare(stock_path, candidate_path):
    stock, candidate = inspect(stock_path), inspect(candidate_path)
    section_changes = differences(stock['sections'], candidate['sections'])
    runtime_changes = differences(stock['runtime_sections'], candidate['runtime_sections'])
    relocation_changes = differences(stock['allocated_target_relocations'],
                                     candidate['allocated_target_relocations'])
    metadata_changes = differences(stock['operational_metadata'], candidate['operational_metadata'])
    abi_equal = stock['abi'] == candidate['abi']
    return {
        'stock': {key: stock[key] for key in ('path', 'size', 'sha256', 'abi', 'sections')},
        'candidate': {key: candidate[key] for key in ('path', 'size', 'sha256', 'abi', 'sections')},
        'allocated_target_relocation_counts': {
            'stock': {name: len(entries) for name, entries
                      in stock['allocated_target_relocations'].items()},
            'candidate': {name: len(entries) for name, entries
                          in candidate['allocated_target_relocations'].items()},
        },
        'full_file_equal': stock['size'] == candidate['size']
        and stock['sha256'] == candidate['sha256'],
        'runtime_equivalent': abi_equal and not runtime_changes and not relocation_changes
        and not metadata_changes,
        'equivalence_scope': 'static code/data, operational metadata, and relocation targets',
        'operational_metadata_differences': metadata_changes,
        'abi_equal': abi_equal, 'runtime_section_differences': runtime_changes,
        'allocated_target_relocation_differences': relocation_changes,
        'all_section_differences': section_changes,
        'ignored_provenance_content': ['.modinfo srcversion= entries',
                                       'GNU build-id descriptor (validated note shape)'],
        'limitations': [
            'Static code/data and relocation comparison does not observe target execution.',
            'Metadata equality does not prove historical lexical source identity.',
            'Embedded firmware arrays are compared as data, not reconstructed firmware source.',
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stock_module', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    if (args.report.resolve() in {args.stock_module.resolve(), args.candidate.resolve()}
            or args.report.exists() and any(args.report.samefile(path)
                                           for path in (args.stock_module, args.candidate)
                                           if path.exists())):
        parser.error('report must not overwrite either input module')
    try:
        report = compare(args.stock_module, args.candidate)
    except (OSError, ELFError, ValueError, IndexError, KeyError) as error:
        report = {'full_file_equal': False, 'runtime_equivalent': False, 'error': str(error)}
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report['runtime_equivalent'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
