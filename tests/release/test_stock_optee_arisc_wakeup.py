"""Compare wake handler/settings and exercise its complete IRQ domain with the real type reader."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/'vendor/optee/standby-host-src'
CROSS=str(ROOT/'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')

@unittest.skipUnless(shutil.which(CROSS+'gcc') and shutil.which('qemu-arm'),'pinned compiler and QEMU required')
class AriscWakeTests(unittest.TestCase):
    def test_encodings_settings_and_irq_configuration(self):
        with tempfile.TemporaryDirectory() as folder:
            out=Path(folder)
            subprocess.run([CROSS+'gcc','-c',SOURCE/'arisc-wakeup.S','-o',out/'handler.o'],check=True)
            subprocess.run([CROSS+'objcopy','-O','binary','-j','.text.sunxi_arisc_handler',out/'handler.o',out/'handler.bin'],check=True)
            code=bytearray((out/'handler.bin').read_bytes());self.assertEqual(len(code),200)
            rel=subprocess.check_output([CROSS+'readelf','-rW',out/'handler.o'],text=True)
            body=rel.split("Relocation section '.rel.text.sunxi_arisc_handler'",1)[1].split('Relocation section',1)[0]
            fields=[0x76,0xb8,0xbc,0xc0,0xc4]
            self.assertEqual([int(x,16) for x in re.findall(r'^([0-9a-f]{8})\s',body,re.M)],fields)
            for o in fields:code[o:o+4]=bytes(4)
            self.assertEqual(hashlib.sha256(code).hexdigest(),'8140624b6926a1f0dfef3d0f89184d58f241a38dd74860c8fbb11496d966db2f')
            subprocess.run([CROSS+'objcopy','-O','binary','-j','.ARM.exidx.text.sunxi_arisc_handler',out/'handler.o',out/'unwind'],check=True)
            self.assertEqual((out/'unwind').read_bytes()[4:8],bytes.fromhex('b0aa0180'))
            subprocess.run([CROSS+'gcc','-c','-Os','-fno-common','-fdata-sections',SOURCE/'standby-state.c','-o',out/'state.o'],check=True)
            subprocess.run([CROSS+'objcopy','-O','binary','-j','.data.standby_host_settings',out/'state.o',out/'settings.bin'],check=True)
            self.assertEqual((out/'settings.bin').read_bytes(),bytes.fromhex('01000000000000400001000000000000'))
            symbols=subprocess.check_output([CROSS+'nm','-S',out/'state.o'],text=True)
            self.assertRegex(symbols,r'00000000 00000080 B standby_host_request')
            subprocess.run([CROSS+'gcc','-static','-Os','-marm','-mcpu=cortex-a7','-Wall','-Wextra','-I'+str(SOURCE),
                            ROOT/'tests/release/stock_optee_arisc_wakeup_guest.c',SOURCE/'arisc-wakeup.S',
                            SOURCE/'standby-state.c',SOURCE/'type.S','-o',out/'guest'],check=True)
            subprocess.run(['qemu-arm',out/'guest'],check=True,timeout=15)

if __name__=='__main__':unittest.main()
