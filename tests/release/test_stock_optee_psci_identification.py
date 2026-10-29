"""Compare complete PSCI response bytes and exercise function-ID namespaces."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
SOURCE = ROOT / 'vendor/optee/standby-host-src/psci-identification.c'


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class PsciIdentificationTests(unittest.TestCase):
    def test_complete_instruction_bytes_and_function_id_ranges(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            (out / 'sm').mkdir()
            # Public PSCI ABI constants; the production build uses upstream sm/psci.h.
            (out / 'sm/psci.h').write_text('''
#define PSCI_FN_BASE 0x84000000U
#define PSCI_VERSION_1_0 0x00010000U
#define PSCI_VERSION PSCI_FN_BASE
#define PSCI_SYSTEM_RESET (PSCI_FN_BASE + 9)
#define PSCI_PSCI_FEATURES (PSCI_FN_BASE + 10)
#define PSCI_SYSTEM_SUSPEND (PSCI_FN_BASE + 14)
#define PSCI_RET_NOT_SUPPORTED (-1)
''')
            subprocess.run([CROSS + 'gcc', '-c', '-Os', '-mthumb', '-march=armv7-a',
                            '-ffunction-sections', '-funwind-tables', '-I' + str(out), SOURCE,
                            '-o', out / 'psci.o'], check=True)
            for name, size, digest in [('psci_version', 6, '083194d6c4f13830a936b3de3d77125ad414635c9620df52a72db7c8a47691c4'),
                                       ('psci_features', 36, '29952bc370cd13b59d7fd61ccad1c40de7a90b1aa2d930c65b1e0c2f2221449c')]:
                subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.' + name,
                                out / 'psci.o', out / (name + '.bin')], check=True)
                body = (out / (name + '.bin')).read_bytes()
                self.assertEqual(len(body), size)
                self.assertEqual(hashlib.sha256(body).hexdigest(), digest)
                subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.ARM.exidx.text.' + name,
                                out / 'psci.o', out / (name + '.unwind')], check=True)
                self.assertEqual((out / (name + '.unwind')).read_bytes()[4:8], bytes.fromhex('b0b0b080'))
            self.assertEqual(subprocess.check_output([CROSS + 'nm', '-u', out / 'psci.o'], text=True).strip(),
                             'U __aeabi_unwind_cpp_pr0')
            relocations = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'psci.o'], text=True)
            self.assertNotIn("'.rel.text.", relocations)
            (out / 'test.c').write_text('''
#include <stdint.h>
extern uint32_t psci_version(void);
extern int psci_features(uint32_t);
static int expected(uint32_t id) {
    return id == 0x84000000 || id == 0x84000009 || id == 0x8400000a || id == 0x8400000e ? 0 : -1;
}
int main(void) {
    const uint32_t bases[] = {0,0x84000000,0x84010000,0xc4000000};
    const uint32_t edges[] = {0xffffffff,0x83ffffff,0x8400000f,0x84000010};
    unsigned b, low;
    if (psci_version() != 0x10000) return 1;
    for (b = 0; b < 4; ++b) for (low = 0; low < 65536; ++low) {
        uint32_t id = bases[b] | low;
        if (psci_features(id) != expected(id)) return 2;
    }
    for (b = 0; b < 4; ++b) if (psci_features(edges[b]) != expected(edges[b])) return 3;
    return 0;
}
''')
            subprocess.run([CROSS + 'gcc', '-static', '-Os', out / 'test.c', out / 'psci.o',
                            '-o', out / 'test'], check=True)
            subprocess.run(['qemu-arm', out / 'test'], check=True, timeout=15)


if __name__ == '__main__':
    unittest.main()
