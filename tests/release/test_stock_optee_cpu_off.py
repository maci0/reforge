"""Check CPU-off bytes/unwind and model its core validation and terminal sequence."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
SOURCE = ROOT / 'vendor/optee/standby-host-src/cpu-off.S'


@unittest.skipUnless(shutil.which(CROSS + 'gcc') and shutil.which('qemu-arm'),
                     'pinned Linaro 5.3.1 and qemu-arm required')
class CpuOffTests(unittest.TestCase):
    def test_bytes_unwind_and_modeled_shutdown_order(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            subprocess.run([CROSS + 'gcc', '-c', SOURCE, '-o', out / 'off.o'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.psci_cpu_off',
                            out / 'off.o', out / 'off.bin'], check=True)
            code = bytearray((out / 'off.bin').read_bytes())
            self.assertEqual(len(code),60)
            rel = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'off.o'], text=True)
            text = rel.split("Relocation section '.rel.text.psci_cpu_off'",1)[1].split('Relocation section',1)[0]
            rows = re.findall(r'^([0-9a-f]{8})\s+\S+\s+(R_ARM_\S+)\s+\S+\s+(.+)$',text,re.MULTILINE)
            expected = [(2,'standby_cpu_get_core'),(0x18,'trace_printf'),(0x1c,'psci_armv7_cpu_off'),
                        (0x22,'thread_mask_exceptions'),(0x34,'.rodata.psci_cpu_off'),(0x38,'.rodata.psci_cpu_off')]
            self.assertEqual([(int(o,16),n) for o,_,n in rows],expected)
            for offset,_ in expected:
                code[offset:offset+4] = bytes(4)
            self.assertEqual(hashlib.sha256(code).hexdigest(),
                             '0a7f96fbba0f4efe7c6b465038bfefc6ce066cf1c66d3bca3ff688751bae6838')
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.ARM.exidx.text.psci_cpu_off',
                            out / 'off.o', out / 'off.unwind'], check=True)
            self.assertEqual((out / 'off.unwind').read_bytes()[4:8],bytes.fromhex('00840280'))
            (out / 'test.c').write_text(r'''
#define _GNU_SOURCE
#include <stdint.h>
#include <signal.h>
#include <stdarg.h>
#include <string.h>
#include <setjmp.h>
#include <ucontext.h>
#include <unistd.h>
extern int psci_cpu_off(void);
static unsigned core, stage;
static sigjmp_buf escape;
static void require(int value) { if (!value) _exit(90); }
unsigned standby_cpu_get_core(void) { require(stage == 0); stage = 1; return core; }
void trace_printf(const char *name, int line, int level, int prefix, const char *format, ...) {
    va_list args;
    require(core == 1 && stage == 1 && line == 209 && level == 3 && prefix == 1);
    require(!strcmp(name,"psci_cpu_off") && !strcmp(format,"core_id: %u"));
    va_start(args,format); require(va_arg(args,unsigned) == 1); va_end(args); stage = 2;
}
void psci_armv7_cpu_off(void) { require(stage == 2); stage = 3; }
unsigned thread_mask_exceptions(unsigned flags) { require(stage == 3 && flags == 7); stage = 4; return 2; }
static void stop_wait(int signal, siginfo_t *info, void *context) {
    ucontext_t *uc = context;
    uintptr_t base = (uintptr_t)psci_cpu_off & ~1u;
    uintptr_t pc = uc->uc_mcontext.arm_pc & ~1u;
    (void)info;
    require(signal == SIGILL || signal == SIGALRM);
    require(stage == 4 && (pc == base+0x26 || (signal == SIGALRM && pc == base+0x28)));
    stage = 5; alarm(0); siglongjmp(escape,1);
}
int main(void) {
    const unsigned invalid[] = {0,2,3,0x101,0xffffffff};
    struct sigaction action = {0}; volatile unsigned i;
    for (i=0;i<5;++i) { core=invalid[i]; stage=0; require(psci_cpu_off() == -2 && stage == 1); }
    action.sa_sigaction=stop_wait; action.sa_flags=SA_SIGINFO;
    require(sigaction(SIGILL,&action,0) == 0 && sigaction(SIGALRM,&action,0) == 0);
    for (i=0;i<4;++i) {
        core=1; stage=0;
        if (!sigsetjmp(escape,1)) { alarm(1); psci_cpu_off(); _exit(91); }
        require(stage == 5);
    }
    return 0;
}
''')
            subprocess.run([CROSS + 'gcc', '-static', '-Os', '-marm', '-mcpu=cortex-a7', '-Wall', '-Wextra',
                            out / 'test.c', SOURCE, '-o', out / 'test'], check=True)
            subprocess.run(['qemu-arm', out / 'test'], check=True, timeout=10)


if __name__ == '__main__':
    unittest.main()
