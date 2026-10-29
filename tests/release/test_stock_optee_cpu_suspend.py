"""Compare the recovered suspend handshake and execute it against private banks."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
SOURCE = ROOT / 'vendor/optee/standby-host-src/cpu-suspend.S'

@unittest.skipUnless(shutil.which(CROSS+'gcc') and shutil.which('qemu-arm'), 'pinned compiler and QEMU required')
class CpuSuspendTests(unittest.TestCase):
    def test_bytes_unwind_and_modeled_suspend(self):
        with tempfile.TemporaryDirectory() as folder:
            out=Path(folder)
            subprocess.run([CROSS+'gcc','-c',SOURCE,'-o',out/'suspend.o'],check=True)
            rel=subprocess.check_output([CROSS+'readelf','-rW',out/'suspend.o'],text=True)
            fields=[0xe,0x26,0x38,0x5c,0x6c,0x70,0x74,0x7a,0xb0,0xb4,0xb8,0xbc,0xc8]
            text=rel.split("Relocation section '.rel.text.psci_cpu_suspend'",1)[1].split('Relocation section',1)[0]
            self.assertEqual([int(x,16) for x in re.findall(r'^([0-9a-f]{8})\s',text,re.MULTILINE)],fields)
            for name,size,offsets,digest in [('psci_cpu_suspend',204,fields,'3c687765788d7439e91490097caf306160d0c6b6de3c01dd051d14e92bc1037c'),
                                          ('standby_gic_cpuif_disable',14,[],'547136a34ec863069ba9a8b9baf971fc23d5db0cb52c75cfae1f088add020d9e')]:
                subprocess.run([CROSS+'objcopy','-O','binary','-j','.text.'+name,out/'suspend.o',out/(name+'.bin')],check=True)
                code=bytearray((out/(name+'.bin')).read_bytes());self.assertEqual(len(code),size)
                for offset in offsets:code[offset:offset+4]=bytes(4)
                self.assertEqual(hashlib.sha256(code).hexdigest(),digest)
            subprocess.run([CROSS+'objcopy','-O','binary','-j','.ARM.exidx.text.psci_cpu_suspend',out/'suspend.o',out/'unwind'],check=True)
            self.assertEqual((out/'unwind').read_bytes()[4:8],bytes.fromhex('b0ac0380'))
            subprocess.run([CROSS+'gcc','-static','-Os','-marm','-mcpu=cortex-a7','-Wall','-Wextra',
                            ROOT/'tests/release/stock_optee_cpu_suspend_guest.c',SOURCE,'-o',out/'guest'],check=True)
            subprocess.run(['qemu-arm',out/'guest'],check=True,timeout=20)

if __name__=='__main__':unittest.main()
