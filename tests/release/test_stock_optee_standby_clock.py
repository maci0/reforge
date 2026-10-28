"""Verify the connected clock/code/data suffix and ordered guest MMIO behavior."""
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
class StandbyClockTests(unittest.TestCase):
    def test_connected_suffix_relocations_and_ordered_clock_registers(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            objects = []
            for name in ('clock-data', 'pmic-setup', 'pmic', 'pmic-data', 'twi'):
                obj = out / (name + '.o')
                subprocess.run([CROSS + 'gcc', '-c', *FLAGS, SOURCE / (name + '.c'), '-o', obj], check=True)
                objects.append(obj)
            for name in ('clock', 'delay', 'power', 'pmic-group', 'descriptor', 'regulator', 'twi-transfer', 'stack', 'spin'):
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
            movw, movt, call = 'R_ARM_MOVW_ABS_NC', 'R_ARM_MOVT_ABS', 'R_ARM_CALL'
            expected = {
                'select': [(4, movw, 'standby_clock_registers'), (8, movt, 'standby_clock_registers')],
                'enter': [(4, movw, 'standby_clock_contexts'), (12, movt, 'standby_clock_contexts'),
                          (100, call, 'standby_delay_us'), (124, movw, 'standby_clock_saved_aux'),
                          (132, movt, 'standby_clock_saved_aux'), (172, call, 'standby_clock_select')],
                'leave': [(36, call, 'standby_delay_ms'), (44, call, 'standby_clock_select'),
                          (52, call, 'standby_delay_ms'), (56, movw, 'standby_clock_saved_aux'),
                          (64, movt, 'standby_clock_saved_aux')],
            }
            relocations = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'clock.o'], text=True)
            for name, wanted in expected.items():
                entries = relocations.split("'.rel.text.standby_clock_" + name + "'", 1)[1].split('Relocation section', 1)[0]
                found = re.findall(r'^([0-9a-f]{8})\s+\S+\s+(R_ARM_\w+)\s+\S+\s+(\S+)', entries, re.M)
                self.assertEqual([(int(a, 16), kind, target) for a, kind, target in found], wanted)
            subprocess.run([CROSS + 'ld', '-T', SOURCE / 'clock-control-runtime.lds', *objects,
                            '-o', out / 'connected.elf'], check=True)
            self.assertFalse(subprocess.check_output([CROSS + 'nm', '-u', out / 'connected.elf']).strip())
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text', '-j', '.data', out / 'connected.elf',
                            out / 'connected.bin'], check=True)
            body = bytearray((out / 'connected.bin').read_bytes())
            self.assertEqual(len(body), 4556)
            # Real data pointers must resolve to the original relative table positions.
            for address, target in ((0x21dcc, 0x21dd0), (0x21e24, 0x21d58),
                                    (0x21e54, 0x21d28), (0x21e84, 0x21d08)):
                offset = address - 0x20f04
                self.assertEqual(int.from_bytes(body[offset:offset + 4], 'little') + 0x20f04, target)
                body[offset:offset + 4] = b'\0' * 4
            fields = [4, 8, 100, 108, 220, 228, 360, 368] + [480 + field for field in
                      [100, 116, 212, 228, 308, 324] + [1648 + value for value in
                       (0, 8, 144, 152, 156, 164, 224, 232, 248, 256, 324, 332)]]
            for offset in fields:
                word = int.from_bytes(body[offset:offset + 4], 'little')
                body[offset:offset + 4] = (word & ~0x000f0fff).to_bytes(4, 'little')
            self.assertEqual(hashlib.sha256(body).hexdigest(),
                             '0aa1aeec12c64cea443c1e831733de7e32f93a87cca8c460c2468f6c24ec7582')
            subprocess.run([CROSS + 'gcc', '-static', *FLAGS, '-Wall', '-Wextra', '-I' + str(SOURCE),
                            ROOT / 'tests/release/stock_optee_standby_clock_guest.c',
                            *[out / (name + '.o') for name in ('clock', 'clock-data', 'delay', 'spin')],
                            '-o', out / 'guest'], check=True)
            subprocess.run(['qemu-arm', out / 'guest'], check=True, timeout=15)


if __name__ == '__main__':
    unittest.main()
