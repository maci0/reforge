"""Keep device and QEMU kernel builds on their respective board sources."""
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
BOARD = ROOT / 'br-external/board/reforge'


@unittest.skipUnless(shutil.which('make'), 'GNU make is required')
class BoardSelectionTest(unittest.TestCase):
    def selected(self, variant=None):
        command = ['make', '--no-print-directory', '-s', '-f', '-',
                   f'BR2_EXTERNAL_REFORGE_PATH={ROOT / "br-external"}']
        if variant:
            command.append(f'REFORGE_KERNEL={variant}')
        result = subprocess.run(command, input='''
.DEFAULT_GOAL := check
include $(BR2_EXTERNAL_REFORGE_PATH)/local.mk
early_config := $(REFORGE_LINUX_CONFIG)
early_dts := $(REFORGE_LINUX_DTS)
include $(BR2_EXTERNAL_REFORGE_PATH)/external.mk
check:
	@printf '%s\\n' '$(early_config)' '$(early_dts)'
''', capture_output=True, text=True, check=True)
        return result.stdout.splitlines()

    def test_device_uses_canonical_stock_source(self):
        self.assertEqual(self.selected(), ['linux.config', 'board.dts'])
        self.assertTrue((BOARD / 'board.dts').is_symlink())
        self.assertEqual((BOARD / 'board.dts').resolve(), BOARD / 'stock/kernel.dts')

    def test_virt_keeps_separate_placeholder(self):
        self.assertEqual(self.selected('virt'), ['linux-virt.config', 'virt/board.dts'])
        self.assertIn('QEMU-only placeholder', (BOARD / 'virt/board.dts').read_text())
        self.assertNotEqual((BOARD / 'virt/board.dts').resolve(), (BOARD / 'board.dts').resolve())

    def test_buildroot_consumes_the_selected_source(self):
        config = (ROOT / 'br-external/configs/reforge_defconfig').read_text()
        self.assertIn('BR2_LINUX_KERNEL_CUSTOM_DTS_PATH="$(BR2_EXTERNAL_REFORGE_PATH)/board/reforge/$(REFORGE_LINUX_DTS)"', config)
        self.assertIn('BR2_PACKAGE_OVERRIDE_FILE="$(BR2_EXTERNAL_REFORGE_PATH)/local.mk"', config)
        for variant in (None, 'virt'):
            path = BOARD / self.selected(variant)[1]
            self.assertTrue(path.is_file())
            self.assertEqual(path.name, 'board.dts')


if __name__ == '__main__':
    unittest.main()
