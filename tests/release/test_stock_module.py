#!/usr/bin/env python3
"""Exercise ARM module verification using actual assembler-produced ELF objects."""
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
HELPER = REPO / 'tools/build/compare-stock-module.py'
SPEC = importlib.util.spec_from_file_location('stock_module', HELPER)
MODULE = importlib.util.module_from_spec(SPEC)
try:
    SPEC.loader.exec_module(MODULE)
except ModuleNotFoundError as error:
    if error.name != 'elftools':
        raise
    MODULE = None
ASSEMBLER = REPO / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-as'


@unittest.skipUnless(MODULE is not None and ASSEMBLER.is_file(),
                     'pyelftools or the original ARM toolchain is not installed')
class StockModuleTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def fixture(self, name, instruction='mov r0, #1', target='external_one',
                metadata='original', local='local.123', bss=16, extra='',
                entries=('vermagic=5.4.61', 'parm=power:int'), metadata_flags='a'):
        source = self.root / (name + '.s')
        output = self.root / (name + '.ko')
        modinfo = '\n'.join(f'    .asciz "{entry}"' for entry in entries)
        source.write_text(f'''
.syntax unified
.arm
.text
.global entry
.type entry, %function
entry:
    {instruction}
    bl {target}
    bx lr
.size entry, .-entry
.data
.type {local}, %object
{local}:
    .word 17
.size {local}, 4
    .word {local}
.bss
    .space {bss}
.section .modinfo,"{metadata_flags}"
    .asciz "srcversion={metadata}"
{modinfo}
{extra}
''')
        subprocess.run([str(ASSEMBLER), '-o', str(output), str(source)], check=True,
                       capture_output=True)
        return output

    def test_identical_and_metadata_only(self):
        stock = self.fixture('stock')
        identical = self.root / 'copy.ko'
        shutil.copyfile(stock, identical)
        report = MODULE.compare(stock, identical)
        self.assertTrue(report['full_file_equal'])
        self.assertTrue(report['runtime_equivalent'])
        candidate = self.fixture('candidate', metadata='reconstructed-longer', local='local.999')
        report = MODULE.compare(stock, candidate)
        self.assertTrue(report['runtime_equivalent'])
        self.assertFalse(report['full_file_equal'])
        changed = {change['name'] for change in report['all_section_differences']}
        self.assertTrue({'.modinfo', '.strtab'} <= changed)
        output = self.root / 'report.json'
        result = subprocess.run([sys.executable, str(HELPER), str(stock), str(candidate),
                                 str(output)], capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(json.loads(output.read_text())['full_file_equal'])

    def test_operational_modinfo_and_order_must_match(self):
        stock = self.fixture('stock')
        for entries in [('vermagic=6.0', 'parm=power:int'),
                        ('vermagic=5.4.61', 'parm=power:uint'),
                        ('parm=power:int', 'vermagic=5.4.61')]:
            with self.subTest(entries=entries):
                report = MODULE.compare(stock, self.fixture('candidate', entries=entries))
                self.assertFalse(report['runtime_equivalent'])
                self.assertTrue(report['operational_metadata_differences'])

    def test_metadata_cannot_hide_executable_flags_or_malformed_entries(self):
        stock = self.fixture('stock')
        for candidate in [self.fixture('executable', metadata_flags='ax'),
                          self.fixture('malformed', entries=('not-a-key-value',)),
                          self.fixture('unterminated', extra='.ascii "unterminated"')]:
            with self.subTest(candidate=candidate.name):
                with self.assertRaises(ValueError):
                    MODULE.compare(stock, candidate)

    def test_build_id_content_only_is_ignored(self):
        note = '''.section .note.gnu.build-id,"a",%note
.balign 4
.long 4, 4, 3
.asciz "GNU"
.long {identifier}
'''
        stock = self.fixture('stock', extra=note.format(identifier=1))
        candidate = self.fixture('candidate', extra=note.format(identifier=2))
        report = MODULE.compare(stock, candidate)
        self.assertTrue(report['runtime_equivalent'])
        self.assertFalse(report['full_file_equal'])
        executable = self.fixture('executable', extra=note.format(identifier=2).replace(
            '"a",%note', '"ax",%note'))
        with self.assertRaises(ValueError):
            MODULE.compare(stock, executable)

    def test_executable_byte_change(self):
        report = MODULE.compare(self.fixture('stock'),
                                self.fixture('candidate', instruction='mov r0, #2'))
        self.assertFalse(report['runtime_equivalent'])
        self.assertIn('.text', [change['name'] for change in report['runtime_section_differences']])

    def test_changed_external_relocation_target(self):
        report = MODULE.compare(self.fixture('stock'),
                                self.fixture('candidate', target='external_two'))
        self.assertFalse(report['runtime_equivalent'])
        self.assertFalse(report['runtime_section_differences'])
        self.assertTrue(report['allocated_target_relocation_differences'])

    def test_bss_size_and_added_allocated_section(self):
        stock = self.fixture('stock')
        for candidate in [self.fixture('larger-bss', bss=20), self.fixture(
                'extra', extra='.section .extra,"a"\n.word 7')]:
            with self.subTest(candidate=candidate.name):
                report = MODULE.compare(stock, candidate)
                self.assertFalse(report['runtime_equivalent'])
                self.assertTrue(report['runtime_section_differences'])
                self.assertFalse(MODULE.compare(candidate, stock)['runtime_equivalent'])

    def test_arm_abi_flags_are_checked(self):
        stock = self.fixture('stock')
        candidate = self.fixture('candidate')
        data = bytearray(candidate.read_bytes())
        flags = struct.unpack_from('<I', data, 36)[0]
        struct.pack_into('<I', data, 36, flags ^ 0x400)
        candidate.write_bytes(data)
        report = MODULE.compare(stock, candidate)
        self.assertFalse(report['abi_equal'])
        self.assertFalse(report['runtime_equivalent'])

    def test_cli_rejects_invalid_elf_and_preserves_inputs(self):
        stock = self.fixture('stock')
        invalid = self.root / 'invalid.ko'
        invalid.write_bytes(b'not ELF')
        report = self.root / 'report.json'
        result = subprocess.run([sys.executable, str(HELPER), str(stock), str(invalid), str(report)],
                                capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(report.read_text())['runtime_equivalent'])
        self.assertIn('error', json.loads(report.read_text()))
        self.assertEqual(invalid.read_bytes(), b'not ELF')


if __name__ == '__main__':
    unittest.main()
