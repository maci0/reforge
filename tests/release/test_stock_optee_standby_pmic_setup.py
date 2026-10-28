"""Verify the extended connected block and original PMIC setup/group behavior."""
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
class StandbyPmicSetupTests(unittest.TestCase):
    def test_connected_block_preparation_group_masks_and_initialization(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            objects = []
            for name in ('pmic-setup', 'pmic', 'pmic-data', 'twi'):
                obj = out / (name + '.o')
                subprocess.run([CROSS + 'gcc', '-c', *FLAGS, SOURCE / (name + '.c'), '-o', obj], check=True)
                objects.append(obj)
            for name in ('power', 'pmic-group', 'descriptor', 'regulator', 'twi-transfer', 'stack', 'spin'):
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
            movw, movt = 'R_ARM_MOVW_ABS_NC', 'R_ARM_MOVT_ABS'
            device = 'standby_pmic_device'
            expected = {
                'pmic-setup': {
                    'prepare': [(4, movw, device), (20, movt, device)] +
                               [(offset, 'R_ARM_CALL', 'standby_pmic_write') for offset in (40, 56, 72, 96)],
                    'read_id': [(16, 'R_ARM_JUMP24', 'standby_twi_transfer')],
                    'initialize': [(12, 'R_ARM_CALL', 'standby_twi_init')],
                },
                'pmic-group': {
                    'group_control': [(8, movw, device), (24, movt, device),
                                      (68, 'R_ARM_CALL', 'standby_find_descriptor'),
                                      (104, movw, device), (120, movt, device),
                                      (128, 'R_ARM_JUMP24', 'standby_pmic_update')],
                },
            }
            for obj, functions in expected.items():
                relocations = subprocess.check_output([CROSS + 'readelf', '-rW', out / (obj + '.o')], text=True)
                for name, wanted in functions.items():
                    entries = relocations.split("'.rel.text.standby_pmic_" + name + "'", 1)[1].split('Relocation section', 1)[0]
                    found = re.findall(r'^([0-9a-f]{8})\s+\S+\s+(R_ARM_\w+)\s+\S+\s+(\S+)', entries, re.M)
                    self.assertEqual([(int(a, 16), kind, target) for a, kind, target in found], wanted)
            subprocess.run([CROSS + 'ld', '-T', SOURCE / 'pmic-control-runtime.lds', *objects,
                            '-o', out / 'connected.elf'], check=True)
            self.assertFalse(subprocess.check_output([CROSS + 'nm', '-u', out / 'connected.elf']).strip())
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text', out / 'connected.elf',
                            out / 'connected.bin'], check=True)
            body = bytearray((out / 'connected.bin').read_bytes())
            self.assertEqual(len(body), 3076)
            fields = [100, 116, 212, 228, 308, 324] + [1648 + field for field in
                      (0, 8, 144, 152, 156, 164, 224, 232, 248, 256, 324, 332)]
            for offset in fields:
                word = int.from_bytes(body[offset:offset + 4], 'little')
                body[offset:offset + 4] = (word & ~0x000f0fff).to_bytes(4, 'little')
            self.assertEqual(hashlib.sha256(body).hexdigest(), 'b7165695763bac1e0769203b54d936aa124685c5bab3b06e1fda9167bd41b0da')
            subprocess.run([CROSS + 'gcc', '-static', *FLAGS, '-Wall', '-Wextra', '-I' + str(SOURCE),
                            ROOT / 'tests/release/stock_optee_standby_pmic_setup_guest.c',
                            *[out / (name + '.o') for name in ('pmic-setup', 'pmic-group', 'pmic', 'pmic-data', 'descriptor')],
                            '-o', out / 'guest'], check=True)
            subprocess.run(['qemu-arm', out / 'guest'], check=True, timeout=60)


if __name__ == '__main__':
    unittest.main()
