"""A relocation counterexample must reject an otherwise near-identical wrapper."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'build/stock-optee-arisc-wakeup/source-b'
STOCK = ROOT / 'build/stock-toc-reconstruction/optee.reference.bin'


@unittest.skipUnless((BUILD / 'build/core/tee.elf').exists() and STOCK.exists(),
                     'recorded source build and stock comparison artifact required')
class CoreTargetAuditTests(unittest.TestCase):
    def test_callee_and_string_bindings_distinguish_matching_wrapper_shapes(self):
        spec = importlib.util.spec_from_file_location('core_targets', ROOT / 'tools/recovery/verify-stock-optee-core-targets.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        report = module.audit(BUILD, STOCK.read_bytes())
        checks = report['checks']
        self.assertEqual(len(checks), 135)
        self.assertEqual(sum(c['status'] == 'callee-body-match' for c in checks), 54)
        self.assertEqual(sum(c['status'] == 'string-match' for c in checks), 49)
        mismatch = [c for c in checks if c['status'] == 'string-differs']
        self.assertEqual(len(mismatch), 1)
        self.assertEqual(mismatch[0]['caller'], 'core_mmu_get_entry')
        self.assertEqual(mismatch[0]['source_string'], 'core_mmu_get_entry')
        callee = next(c for c in checks if c['caller'] == 'core_mmu_get_entry' and c['symbol'] == 'core_mmu_get_entry_primitive')
        self.assertEqual(callee['status'], 'callee-body-differs')
        with self.assertRaises(AssertionError):
            module.audit(BUILD, b'invalid reference')


if __name__ == '__main__':
    unittest.main()
