"""Compare CPU control source encodings/unwind and execute against private register banks."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
SOURCE = ROOT / 'vendor/optee/standby-host-src/cpu-control.S'


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class CpuControlTests(unittest.TestCase):
    def test_instruction_bytes_unwind_and_modeled_register_paths(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            subprocess.run([CROSS + 'gcc', '-c', SOURCE, '-o', out / 'cpu.o'], check=True)
            relocations = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'cpu.o'], text=True)
            cases = [
                ('psci_cpu_on',124,[0x1e,0x2a,0x4c,0x68,0x6c,0x70,0x74,0x78],
                 'f9a6faa20035b7a59203ecf767ff70228cfbcfc1e33a0bb0b73187c20fdc872a','b0aa0380'),
                ('psci_affinity_info',80,[4,0x18,0x44,0x48,0x4c],
                 '8205bff7a8431dbfa9bcb6215ad245981b0c05ac68bac60b1d7ec7e5e09dc5a4','b0a80380'),
                ('standby_cpu_get_core',48,[2,0x12,0x16,0x1e,0x24,0x28,0x2c],
                 '577cc18b4d44aef5089d2e10363303c3d014c2be4292c3a17cdec6f172076370',None),
            ]
            for name, size, offsets, digest, unwind in cases:
                subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.' + name,
                                out / 'cpu.o', out / (name + '.bin')], check=True)
                code = bytearray((out / (name + '.bin')).read_bytes())
                self.assertEqual(len(code), size)
                section = relocations.split("Relocation section '.rel.text." + name + "'",1)[1].split('Relocation section',1)[0]
                self.assertEqual([int(x,16) for x in re.findall(r'^([0-9a-f]{8})\s',section,re.MULTILINE)],offsets)
                for offset in offsets:
                    code[offset:offset+4] = bytes(4)
                self.assertEqual(hashlib.sha256(code).hexdigest(),digest)
                if unwind:
                    subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.ARM.exidx.text.' + name,
                                    out / 'cpu.o', out / (name + '.unwind')], check=True)
                    self.assertEqual((out / (name + '.unwind')).read_bytes()[4:8],bytes.fromhex(unwind))
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.ARM.extab.text.standby_cpu_get_core',
                            out / 'cpu.o', out / 'core.extab'], check=True)
            self.assertEqual((out / 'core.extab').read_bytes(),bytes.fromhex('08b10181b0b0008400000000'))
            subprocess.run([CROSS + 'gcc', '-static', '-Os', '-marm', '-mcpu=cortex-a7', '-Wall', '-Wextra',
                            ROOT / 'tests/release/stock_optee_cpu_control_guest.c', SOURCE,
                            '-o', out / 'guest'], check=True)
            subprocess.run(['qemu-arm', out / 'guest'], check=True, timeout=15)


if __name__ == '__main__':
    unittest.main()
