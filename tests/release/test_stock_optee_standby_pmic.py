"""Check compiled PMIC helpers and their register/error semantics on ARM."""
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
         '-fno-builtin', '-fno-unwind-tables', '-ffunction-sections']


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class StandbyPmicTests(unittest.TestCase):
    def test_original_tables_and_linked_descriptor_pointers(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            subprocess.run([CROSS + 'gcc', '-c', *FLAGS, SOURCE / 'pmic-data.c',
                            '-o', out / 'pmic-data.o'], check=True)
            tables = {
                'ranges_3': (32, [], 'c6dc126a513827965d182fe4294b5289ed24d49b70f702e1ec5bace8be17f999'),
                'ranges_2': (48, [], '6304738977bfbb502c262566704b0ee38e2e5a78dd7f2d9dadf1b056aa160d66'),
                'ranges_1': (32, [], '1d0612c91c2e4d39b0a49e63f7bba41201c855b44765972c8cd87501ba60ddd3'),
                'device': (16, [(12, 'entries')], 'ef4097f995a2af33eb31599bb6844f37d4c3057ff7a9fd1285ab72b4cca9405d'),
                'entries': (768, [(84, 'ranges_1'), (132, 'ranges_2'), (180, 'ranges_3')],
                            'eae2576fdf51a250e6f6a06fce69ca97b7f4ea801d6f06bdb29e20b8272ca2dc'),
            }
            relocations = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'pmic-data.o'], text=True)
            for name, (size, relocations_expected, digest) in tables.items():
                section = ('.data.' if name == 'device' else '.rodata.') + 'standby_pmic_' + name
                subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', section,
                                out / 'pmic-data.o', out / 'table.bin'], check=True)
                body = bytearray((out / 'table.bin').read_bytes())
                self.assertEqual(len(body), size)
                marker = "'.rel" + section + "'"
                found = []
                if marker in relocations:
                    entries = relocations.split(marker, 1)[1].split('Relocation section', 1)[0]
                    found = re.findall(r'^([0-9a-f]{8})\s+\S+\s+(R_ARM_\w+)\s+\S+\s+(\S+)', entries, re.M)
                self.assertEqual([(int(a, 16), kind, target) for a, kind, target in found],
                                 [(offset, 'R_ARM_ABS32', 'standby_pmic_' + target)
                                  for offset, target in relocations_expected])
                for offset, _ in relocations_expected:
                    body[offset:offset + 4] = b'\0' * 4
                self.assertEqual(hashlib.sha256(body).hexdigest(), digest)
            (out / 'test.c').write_text(r'''
#include "pmic-data.h"
extern const struct standby_pmic_entry *standby_find_descriptor(const struct standby_pmic_device *, unsigned);
int main(void) {
    unsigned i;
    if (standby_pmic_device.address || standby_pmic_device.count != 16) return 1;
    if (standby_pmic_device.entries != standby_pmic_entries) return 2;
    for (i = 0; i < 16; ++i)
        if (standby_find_descriptor(&standby_pmic_device, 1u << i) != &standby_pmic_entries[i]) return 3;
    if (standby_find_descriptor(&standby_pmic_device, 0)) return 4;
    /* Preserve the original inclusive-bound mismatch, never dereference this pointer. */
    if (standby_find_descriptor(&standby_pmic_device, 1u << 16) != standby_pmic_entries + 16) return 5;
    if (standby_pmic_entries[1].ranges != standby_pmic_ranges_1 || standby_pmic_entries[1].range_count != 2) return 6;
    if (standby_pmic_entries[2].ranges != standby_pmic_ranges_2 || standby_pmic_entries[2].range_count != 3) return 7;
    if (standby_pmic_entries[3].ranges != standby_pmic_ranges_3 || standby_pmic_entries[3].range_count != 2) return 8;
    if (standby_pmic_ranges_1[1].minimum_uv != 1220000 || standby_pmic_ranges_2[2].minimum_uv != 1600000) return 9;
    return 0;
}
__asm__(".text\n.arm\n.global _start\n_start:\nbl main\nmov r7,#1\nsvc #0\n");
''')
            subprocess.run([CROSS + 'gcc', '-nostdlib', '-static', *FLAGS, '-I' + str(SOURCE),
                            '-Wl,-e,_start', out / 'test.c', SOURCE / 'descriptor.S',
                            out / 'pmic-data.o', '-o', out / 'test'], check=True)
            subprocess.run(['qemu-arm', out / 'test'], check=True, timeout=10)

    def test_original_instructions_and_register_transactions(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            subprocess.run([CROSS + 'gcc', '-c', *FLAGS, SOURCE / 'pmic.c',
                            '-o', out / 'pmic.o'], check=True)
            expected = {
                'read': (20, [16], '20185a79231fb8ec0fb0273b271029b5ce47bdb43d3194f3f92f3ca601a8264b'),
                'write': (20, [16], '8acaaaf2e4e23ce9409aeef9d26ecfb34a460a0905ef31b6be47eab44f9159a4'),
                'update': (120, [48, 108], '6092aa77152a5323fad497545408e2a3d646ad86892cbcaa5fe668ab8adf3256'),
            }
            relocations = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'pmic.o'], text=True)
            for name, (size, offsets, digest) in expected.items():
                section = '.text.standby_pmic_' + name
                subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', section,
                                out / 'pmic.o', out / 'body.bin'], check=True)
                body = bytearray((out / 'body.bin').read_bytes())
                self.assertEqual(len(body), size)
                entries = relocations.split("'.rel" + section + "'", 1)[1].split('Relocation section', 1)[0]
                found = re.findall(r'^([0-9a-f]{8})\s+\S+\s+(R_ARM_\w+)\s+\S+\s+(\S+)', entries, re.M)
                self.assertEqual([(int(a, 16), kind, target) for a, kind, target in found],
                                 [(offset, 'R_ARM_CALL' if name == 'update' else 'R_ARM_JUMP24',
                                   'standby_twi_transfer') for offset in offsets])
                for offset in offsets:
                    body[offset:offset + 4] = b'\0' * 4
                self.assertEqual(hashlib.sha256(body).hexdigest(), digest)
            (out / 'test.c').write_text(r'''
#include "pmic.h"
static unsigned calls, bad, original, written, expected_reg;
static int read_error, write_error;
int standby_twi_transfer(unsigned write, unsigned address, unsigned reg, uint8_t *value) {
    if (address != 0x34 || reg != expected_reg || !value || write > 1) bad = 1;
    ++calls;
    if (!write) {
        if (calls != 1) bad = 2;
        *value = original;
        return read_error;
    }
    written = *value;
    return write_error;
}
static void reset(unsigned old, unsigned reg) {
    calls = bad = 0; written = 0x100; original = old; expected_reg = reg;
    read_error = write_error = 0;
}
int main(void) {
    const uint8_t device[] = {0x34, 0x7f};
    uint8_t value; unsigned old, mask, i;
    int result;
    reset(0xab, 0x12345678);
    if (standby_pmic_read(device, expected_reg, &value) || value != 0xab || calls != 1 || bad) return 1;
    reset(0, 0x82); value = 0xcd; write_error = -19;
    if (standby_pmic_write(device, expected_reg, &value) != -19 || calls != 1 || written != 0xcd || bad) return 2;
    reset(0, 0x90); read_error = -7;
    if (standby_pmic_update(device, expected_reg, 3, 7) != -7 || calls != 1 || written != 0x100 || bad) return 3;
    for (old = 0; old < 256; ++old) for (mask = 0; mask < 256; ++mask) {
        const unsigned values[] = {0, mask, ~mask, old & mask, 0x100};
        for (i = 0; i < sizeof(values) / sizeof(values[0]); ++i) {
            unsigned request = values[i];
            unsigned needs_write = (old & mask) != request;
            unsigned expected = (uint8_t)((old & ~mask) | (request & mask));
            reset(old, 0x90); write_error = -19;
            result = standby_pmic_update(device, expected_reg, request, mask);
            if (bad || calls != 1 + needs_write || result != (needs_write ? -19 : 0)) return 4;
            if (written != (needs_write ? expected : 0x100)) return 5;
        }
    }
    reset(0xa5, 0x91);
    if (standby_pmic_update(device, expected_reg, 0x155, 0x1ff) || calls != 2 || written != 0x55 || bad) return 6;
    reset(0xff, 0x91);
    if (standby_pmic_update(device, expected_reg, 0, 0x100) || calls != 1 || bad) return 7;
    return 0;
}
__asm__(".text\n.arm\n.global _start\n_start:\nbl main\nmov r7,#1\nsvc #0\n");
''')
            subprocess.run([CROSS + 'gcc', '-nostdlib', '-static', *FLAGS, '-I' + str(SOURCE),
                            '-Wl,-e,_start', out / 'test.c', out / 'pmic.o', '-o', out / 'test'], check=True)
            subprocess.run(['qemu-arm', out / 'test'], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
