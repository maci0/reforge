"""Build the connected TWI engine; verify stock instructions and a reactive MMIO model."""
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
class StandbyTwiTests(unittest.TestCase):
    def test_linked_block_relocations_and_reactive_register_protocol(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            subprocess.run([CROSS + 'gcc', '-c', *FLAGS, SOURCE / 'twi.c',
                            '-o', out / 'twi.o'], check=True)
            subprocess.run([CROSS + 'gcc', '-c', '-marm', '-march=armv7-a', SOURCE / 'twi-transfer.S',
                            '-o', out / 'twi-transfer.o'], check=True)
            movw, movt = 'R_ARM_MOVW_ABS_NC', 'R_ARM_MOVT_ABS'
            state, bases, stop = 'standby_twi_state', 'standby_twi_bases', 'standby_twi_stop'
            expected = {
                'twi-transfer': {
                    'stop': [(0, movw, state), (8, movt, state)],
                    'transfer': [(20, 'R_ARM_CALL', stop), (24, movw, state),
                                 (32, movt, state), (64, 'R_ARM_CALL', stop)],
                },
                'twi': {
                    'init': [(0, movw, bases), (8, movt, bases), (12, movw, state), (20, movt, state)],
                    'set_divider': [(0, movw, state), (8, movt, state)],
                    'restore': [(0, movw, state), (8, movt, state)],
                },
            }
            for obj, functions in expected.items():
                relocations = subprocess.check_output([CROSS + 'readelf', '-rW', out / (obj + '.o')], text=True)
                for name, wanted in functions.items():
                    marker = "'.rel.text.standby_twi_" + name + "'"
                    entries = relocations.split(marker, 1)[1].split('Relocation section', 1)[0]
                    found = re.findall(r'^([0-9a-f]{8})\s+\S+\s+(R_ARM_\w+)\s+\S+\s+(\S+)', entries, re.M)
                    self.assertEqual([(int(a, 16), kind, target) for a, kind, target in found], wanted)
            subprocess.run([CROSS + 'ld', '-T', SOURCE / 'twi.lds', out / 'twi-transfer.o',
                            out / 'twi.o', '-o', out / 'twi.elf'], check=True)
            self.assertFalse(subprocess.check_output([CROSS + 'nm', '-u', out / 'twi.elf']).strip())
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text', out / 'twi.elf',
                            out / 'twi.bin'], check=True)
            body = bytearray((out / 'twi.bin').read_bytes())
            self.assertEqual(len(body), 932)
            # Mask only each real MOVW/MOVT immediate, keeping opcode and register bits.
            for offset in (0, 8, 144, 152, 156, 164, 224, 232, 248, 256, 324, 332):
                word = int.from_bytes(body[offset:offset + 4], 'little')
                body[offset:offset + 4] = (word & ~0x000f0fff).to_bytes(4, 'little')
            self.assertEqual(hashlib.sha256(body).hexdigest(),
                             '074dbdd7b7e37cda4b0c3c8bb47771cba66f8d17c81b27e59e365086f1b358b4')
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.rodata', out / 'twi.elf',
                            out / 'bases.bin'], check=True)
            self.assertEqual((out / 'bases.bin').read_bytes(),
                             b''.join(address.to_bytes(4, 'little') for address in
                                      (0x02502000, 0x02502400, 0x02502800, 0x02502c00, 0x02503000)))
            subprocess.run([CROSS + 'gcc', '-static', *FLAGS, '-Wall', '-Wextra', '-I' + str(SOURCE),
                            ROOT / 'tests/release/stock_optee_standby_twi_guest.c',
                            out / 'twi-transfer.o', out / 'twi.o', SOURCE / 'pmic.c',
                            '-o', out / 'guest'], check=True)
            subprocess.run(['qemu-arm', out / 'guest'], check=True, timeout=120)


if __name__ == '__main__':
    unittest.main()
