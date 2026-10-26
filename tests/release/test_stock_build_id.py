"""Check the checksum model against the actual historical linker."""
import importlib.util
from io import BytesIO
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('build_id', ROOT / 'tools/build/calculate-stock-build-id.py')
MODEL = importlib.util.module_from_spec(SPEC)
try:
    SPEC.loader.exec_module(MODEL)
except ModuleNotFoundError as error:
    if error.name != 'elftools':
        raise
    MODEL = None
CROSS = ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-'


@unittest.skipUnless(MODEL and Path(str(CROSS) + 'ld').is_file(), 'requires pyelftools and pinned toolchain')
class BuildIdTest(unittest.TestCase):
    def test_linker_digest_and_debug_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, obj, output = (root / name for name in ('input.s', 'input.o', 'output.elf'))
            source.write_text('.syntax unified\n.arm\n.text\n.global _start\n_start: bx lr\n'
                              '.section .debug_str,"MS",%progbits,1\n.asciz "original-name"\n')
            subprocess.run([str(CROSS) + 'as', '-o', obj, source], check=True, capture_output=True)
            subprocess.run([str(CROSS) + 'ld', '--build-id=sha1', '-o', output, obj],
                           check=True, capture_output=True)
            data = output.read_bytes()
            self.assertTrue(MODEL.calculate(data)['matches'])
            elf = MODEL.ELFFile(BytesIO(data))
            section = elf.get_section_by_name('.debug_str')
            self.assertFalse(section['sh_flags'] & 2)  # Not loaded at runtime.
            changed = bytearray(data)
            changed[section['sh_offset']] ^= 1
            self.assertFalse(MODEL.calculate(changed)['matches'])
            self.assertEqual(output.read_bytes(), data)


if __name__ == '__main__':
    unittest.main()
