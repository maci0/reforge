"""Compare resume instructions and verify ARM/Thumb symbolic call linkage."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CROSS = str(ROOT / 'vendor/toolchains/gcc-linaro-5.3.1-2016.05-x86_64_arm-linux-gnueabi/bin/arm-linux-gnueabi-')
SOURCE = ROOT / 'vendor/optee/standby-host-src/resume.S'


@unittest.skipUnless(shutil.which(CROSS + 'gcc'), 'pinned Linaro 5.3.1 required')
class HostResumeTests(unittest.TestCase):
    def test_instruction_bytes_and_interworking(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            subprocess.run([CROSS + 'gcc', '-c', SOURCE, '-o', out / 'resume.o'], check=True)
            subprocess.run([CROSS + 'objcopy', '-O', 'binary', '-j', '.text.standby_host_resume',
                            out / 'resume.o', out / 'resume.bin'], check=True)
            code = bytearray((out / 'resume.bin').read_bytes())
            self.assertEqual(len(code), 156)
            relocations = subprocess.check_output([CROSS + 'readelf', '-rW', out / 'resume.o'], text=True)
            self.assertIn('R_ARM_JUMP24', relocations.split("'.rel.text.standby_host_resume'", 1)[0])
            body = relocations.split("'.rel.text.standby_host_resume'", 1)[1]
            rows = re.findall(r'^([0-9a-f]{8})\s+\S+\s+(R_ARM_\S+)\s+\S+\s+(.+)$', body, re.MULTILINE)
            expected = [(0,'R_ARM_CALL','plat_cpu_reset_early'), (0x2c,'R_ARM_CALL','__get_core_pos'),
                        (0x34,'R_ARM_JUMP24','unhandled_cpu'), (0x50,'R_ARM_CALL','standby_resume_platform_init'),
                        (0x54,'R_ARM_CALL','standby_resume_select_state'), (0x5c,'R_ARM_CALL','dcache_op_level1'),
                        (0x60,'R_ARM_CALL','core_init_mmu_regs'), (0x64,'R_ARM_CALL','cpu_mmu_enable'),
                        (0x68,'R_ARM_CALL','cpu_mmu_enable_icache'), (0x6c,'R_ARM_CALL','cpu_mmu_enable_dcache'),
                        (0x70,'R_ARM_CALL','standby_resume_secondary_init'),
                        (0x90,'R_ARM_ABS32','reset_vect_table'), (0x94,'R_ARM_ABS32','stack_tmp_stride'),
                        (0x98,'R_ARM_ABS32','stack_tmp_export')]
            self.assertEqual([(int(o,16), k, n) for o,k,n in rows], expected)
            for offset, _, _ in expected:
                code[offset:offset + 4] = bytes(4)
            self.assertEqual(hashlib.sha256(code).hexdigest(),
                             '2230668d7c920ac6d795b0b50fea8a4ffe6d9542aa92120db6a33c485a313545')
            thumb = {'standby_resume_platform_init', 'standby_resume_select_state',
                     'core_init_mmu_regs', 'standby_resume_secondary_init'}
            # Link-only traps validate interworking without executing privileged reset code.
            fixture = ['.syntax unified', '.arch armv7-a', '.text']
            for _, kind, name in expected:
                if kind == 'R_ARM_ABS32':
                    fixture += ['.data', '.balign 4', '.global ' + name, name + ': .word 0']
                else:
                    fixture += ['.text', '.thumb' if name in thumb else '.arm', '.balign 4',
                                '.global ' + name, '.type ' + name + ',%function']
                    if name in thumb:
                        fixture += ['.thumb_func']
                    fixture += [name + ': udf #0']
            fixture += ['.section .note.GNU-stack,"",%progbits']
            (out / 'fixture.S').write_text('\n'.join(fixture) + '\n')
            subprocess.run([CROSS + 'gcc', '-c', out / 'fixture.S', '-o', out / 'fixture.o'], check=True)
            subprocess.run([CROSS + 'ld', '-Ttext=0x10000', '-e', 'standby_host_resume_entry',
                            out / 'resume.o', out / 'fixture.o', '-o', out / 'resume.elf'], check=True)
            self.assertFalse(subprocess.check_output([CROSS + 'nm', '-u', out / 'resume.elf']).strip())
            assembly = subprocess.check_output([CROSS + 'objdump', '-d', out / 'resume.elf'], text=True)
            for _, kind, name in expected:
                if kind == 'R_ARM_ABS32':
                    continue
                op = 'blx' if name in thumb else ('bge' if name == 'unhandled_cpu' else 'bl')
                self.assertRegex(assembly, rf'\b{op}\s+[0-9a-f]+ <{name}>')
            self.assertRegex(assembly, r'\bb\s+[0-9a-f]+ <standby_host_resume>')


if __name__ == '__main__':
    unittest.main()
