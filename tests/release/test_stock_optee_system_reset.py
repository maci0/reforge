"""Compare reset instructions/unwind and observe writes in a QEMU private register model."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
SOURCE = ROOT / 'vendor/optee/standby-host-src/system-reset.S'


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class SystemResetTests(unittest.TestCase):
    def test_reset_bytes_unwind_and_private_watchdog_writes(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            subprocess.run([CROSS + 'gcc', '-c', SOURCE, '-o', out / 'reset.o'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.psci_system_reset',
                            out / 'reset.o', out / 'reset.bin'], check=True)
            code = bytearray((out / 'reset.bin').read_bytes())
            self.assertEqual(len(code),32)
            rel = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'reset.o'], text=True)
            text = rel.split("Relocation section '.rel.text.psci_system_reset'",1)[1].split('Relocation section',1)[0]
            rows = re.findall(r'^([0-9a-f]{8})\s+\S+\s+(R_ARM_\S+)\s+\S+\s+(.+)$',text,re.MULTILINE)
            self.assertEqual(rows,[('00000004','R_ARM_THM_CALL','phys_to_virt_io')])
            code[4:8] = bytes(4)
            self.assertEqual(hashlib.sha256(code).hexdigest(),'5143bfe56f0d239d33b6ce28a7f2a5bae308097bab2b291bb9f5cca5cf22654a')
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.ARM.extab.text.psci_system_reset',
                            out / 'reset.o', out / 'reset.extab'], check=True)
            self.assertEqual((out / 'reset.extab').read_bytes(),bytes.fromhex('08b10181b0b0008400000000'))
            (out / 'test.c').write_text(r'''
#define _GNU_SOURCE
#include <stdint.h>
#include <signal.h>
#include <setjmp.h>
#include <ucontext.h>
#include <unistd.h>
extern void psci_system_reset(void);
static volatile uint32_t registers[16];
static uint32_t initial[16];
static volatile unsigned mappings, stops;
static sigjmp_buf escape;
static void require(int value) { if (!value) _exit(90); }
void *phys_to_virt_io(uint32_t physical) {
    require(physical == 0x07020800 && mappings == 0); ++mappings;
    return (void *)registers;
}
static void stop_wait(int signal, siginfo_t *info, void *context) {
    ucontext_t *uc = context;
    uintptr_t base = (uintptr_t)psci_system_reset & ~1u;
    uintptr_t pc = uc->uc_mcontext.arm_pc & ~1u;
    unsigned i;
    (void)info;
    require(mappings == 1 && stops == 0);
    require(signal == SIGILL || signal == SIGALRM);
    require(pc == base + 0x12 || (signal == SIGALRM && pc == base + 0x14));
    for (i=0;i<16;++i) require(registers[i] == (i==4 ? 0x203 : i==5 ? 0x0d140001 : initial[i]));
    ++stops; alarm(0); siglongjmp(escape,1);
}
int main(void) {
    struct sigaction action = {0}; unsigned c,i;
    action.sa_sigaction = stop_wait; action.sa_flags = SA_SIGINFO;
    require(sigaction(SIGILL,&action,0) == 0 && sigaction(SIGALRM,&action,0) == 0);
    for (c=0;c<4;++c) {
        for (i=0;i<16;++i) registers[i] = initial[i] = 0xa55aa55a ^ (i*0x01010101) ^ c;
        mappings = stops = 0;
        if (!sigsetjmp(escape,1)) { alarm(1); psci_system_reset(); _exit(91); }
        require(stops == 1);
    }
    return 0;
}
''')
            subprocess.run([CROSS + 'gcc', '-static', '-Os', '-marm', '-mcpu=cortex-a7', '-Wall', '-Wextra',
                            out / 'test.c', SOURCE, '-o', out / 'test'], check=True)
            subprocess.run(['qemu-arm', out / 'test'], check=True, timeout=10)


if __name__ == '__main__':
    unittest.main()
