"""Compare runtime memory checks and execute the actual compiled core function."""
import hashlib
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from elftools.elf.elffile import ELFFile

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'build/stock-optee-memory-bounds/source-a'
STOCK = ROOT / 'build/stock-toc-reconstruction/optee.reference.bin'
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')


@unittest.skipUnless((BUILD / 'build/core/arch/arm/mm/core_mmu.o').exists()
                     and STOCK.exists() and shutil.which('qemu-arm'),
                     'recorded memory-bounds source build, stock and QEMU required')
class MemoryBoundsTests(unittest.TestCase):
    def test_full_section_and_production_runtime(self):
        with (BUILD / 'build/core/arch/arm/mm/core_mmu.o').open('rb') as stream:
            elf = ELFFile(stream)
            section = elf.get_section_by_name('.text.core_pbuf_is')
            source = bytearray(section.data())
            self.assertEqual(len(source), 228)
            stock = bytearray(STOCK.read_bytes()[0xd4cc:0xd5b0])
            rels = list(elf.get_section_by_name('.rel' + section.name).iter_relocations())
            self.assertEqual(sorted(r['r_offset'] for r in rels),
                             [32,38,72,120,126,142,178,188,192,196,200,208,212,216,220,224])
            for rel in rels:
                self.assertIn(rel['r_info_type'], (2,10,30))
                off = rel['r_offset']
                source[off:off+4] = bytes(4)
                stock[off:off+4] = bytes(4)
            self.assertEqual(source, stock)
            self.assertEqual(hashlib.sha256(source).hexdigest(), '131bc81eb3e71dabb3dfae46fdb79f94ee22188fba08807a4fde538a6fadc45d')
        header = (BUILD / 'source-tree/core/arch/arm/include/mm/core_memprot.h').read_text()
        enum = re.search(r'enum buf_is_attr\s*\{[^}]+\};', header).group()
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            (out / 'memory-bounds-attributes.h').write_text(enum + '\n')
            subprocess.run([CROSS+'gcc','-static','-Os','-ffunction-sections','-fdata-sections',
                            '-Wl,--gc-sections','-Wall','-Wextra','-I'+folder,
                            ROOT/'tests/release/stock_optee_memory_bounds_guest.c',
                            BUILD/'build/core/arch/arm/mm/core_mmu.o',
                            BUILD/'build/core/kernel/tee_misc.o','-o',out/'guest'], check=True)
            subprocess.run(['qemu-arm',out/'guest'],check=True,timeout=15)


if __name__ == '__main__':
    unittest.main()
