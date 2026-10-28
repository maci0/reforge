"""Verify the connected PMIC/regulator/TWI/runtime block and regulator semantics."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'vendor/optee/standby-src'
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
FLAGS = ['-O2', '-marm', '-march=armv7-a', '-mtune=cortex-a9', '-ffreestanding',
         '-fno-builtin', '-fno-unwind-tables', '-ffunction-sections', '-fno-section-anchors']


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class StandbyRegulatorTests(unittest.TestCase):
    def test_connected_block_tables_voltage_enable_and_stack(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            objects = []
            for name in ('pmic', 'pmic-data', 'twi'):
                obj = out / (name + '.o')
                subprocess.run([CROSS + 'gcc', '-c', *FLAGS, SOURCE / (name + '.c'), '-o', obj], check=True)
                objects.append(obj)
            for name in ('descriptor', 'regulator', 'twi-transfer', 'stack', 'spin'):
                obj = out / (name + '.o')
                subprocess.run([CROSS + 'gcc', '-c', '-marm', '-march=armv7-a', SOURCE / (name + '.S'),
                                '-o', obj], check=True)
                objects.append(obj)
            shutil.copy2(SOURCE / 'runtime/lib1funcs.S', out / 'lib1funcs.S')
            subprocess.run(['patch', '--batch', '--fuzz=0', '-p1', '-i', SOURCE / 'runtime/standby-div0.patch'],
                           cwd=out, check=True, capture_output=True)
            subprocess.run([CROSS + 'gcc', '-c', '-marm', '-march=armv7-a', '-D__ASSEMBLY__',
                            '-D__UBOOT__', '-D__LINUX_ARM_ARCH__=7', '-I' + str(SOURCE / 'runtime/abi'),
                            out / 'lib1funcs.S', '-o', out / 'runtime.o'], check=True)
            objects.append(out / 'runtime.o')
            subprocess.run([CROSS + 'ld', '-T', SOURCE / 'pmic-twi-runtime.lds', *objects,
                            '-o', out / 'connected.elf'], check=True)
            self.assertFalse(subprocess.check_output([CROSS + 'nm', '-u', out / 'connected.elf']).strip())
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text', out / 'connected.elf',
                            out / 'connected.bin'], check=True)
            body = bytearray((out / 'connected.bin').read_bytes())
            self.assertEqual(len(body), 2696)
            relocations = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'regulator.o'], text=True)
            expected_calls = {
                'set_voltage': [(256, '__aeabi_uidiv'), (288, 'standby_twi_transfer'),
                                (360, 'standby_twi_transfer'), (404, '__aeabi_uidiv')],
                'get_voltage': [(92, 'standby_twi_transfer')],
                'set_enabled': [(84, 'standby_pmic_update'), (116, 'standby_pmic_update')],
                'get_enabled': [(92, 'standby_twi_transfer')],
            }
            for name, wanted in expected_calls.items():
                entries = relocations.split("'.rel.text.standby_regulator_" + name + "'", 1)[1].split('Relocation section', 1)[0]
                found = re.findall(r'^([0-9a-f]{8})\s+\S+\s+(R_ARM_\w+)\s+\S+\s+(\S+)', entries, re.M)
                self.assertEqual([(int(a, 16), kind, target) for a, kind, target in found],
                                 [(offset, 'R_ARM_JUMP24' if name == 'set_enabled' else 'R_ARM_CALL', target)
                                  for offset, target in wanted])
            # Only the TWI global-address immediate bits remain layout-dependent.
            for field in (0, 8, 144, 152, 156, 164, 224, 232, 248, 256, 324, 332):
                offset = 1268 + field
                word = int.from_bytes(body[offset:offset + 4], 'little')
                body[offset:offset + 4] = (word & ~0x000f0fff).to_bytes(4, 'little')
            self.assertEqual(hashlib.sha256(body).hexdigest(),
                             '9a19fe0779a925ffccd3b56538b604fd3dd83a3ab4790760dd81c7d16c79d4c2')
            # Keep the test executable outside the guest SRAM stack page.
            subprocess.run([CROSS + 'gcc', '-static', *FLAGS, '-Wall', '-Wextra',
                            '-Wl,-Ttext-segment=0x100000', '-I' + str(SOURCE),
                            ROOT / 'tests/release/stock_optee_standby_regulator_guest.c',
                            *[out / (name + '.o') for name in ('regulator', 'pmic', 'pmic-data', 'stack', 'runtime')],
                            '-o', out / 'guest'], check=True)
            for mode in ('', 's', 'g', 'e', 'q'):
                subprocess.run(['qemu-arm', out / 'guest'] + ([mode] if mode else []), check=True, timeout=15)


if __name__ == '__main__':
    unittest.main()
