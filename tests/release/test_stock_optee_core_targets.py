"""A relocation counterexample must reject an otherwise near-identical wrapper."""
import importlib.util
import json
import tempfile
from unittest.mock import patch
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
        self.assertEqual(sum(c['status'] == 'callee-body-match' for c in checks), 55)
        self.assertEqual(sum(c['status'] == 'string-match' for c in checks), 50)
        self.assertFalse(any(c['status'] == 'string-differs' for c in checks))
        callee = next(c for c in checks if c['caller'] == 'core_mmu_get_entry' and c['symbol'] == 'core_mmu_get_entry_primitive')
        self.assertEqual(callee['status'], 'callee-body-match')
        proof_path = Path('docs/board-notes/stock-optee-core-immediates-proof.json')
        proof = json.loads((ROOT / proof_path).read_text())
        next(r for r in proof['routines'] if r['section'] == '.text.core_mmu_get_entry')['stock_offset'] = '0xd630'
        with tempfile.TemporaryDirectory() as folder:
            altered = Path(folder) / proof_path
            altered.parent.mkdir(parents=True)
            altered.write_text(json.dumps(proof))
            with patch.object(module, 'ROOT', Path(folder)):
                rejected = module.audit(BUILD, STOCK.read_bytes())['checks']
            mismatch = [c for c in rejected if c['status'] == 'string-differs']
            self.assertEqual(len(mismatch), 1)
            self.assertEqual(mismatch[0]['caller'], 'core_mmu_get_entry')
            wrong_callee = next(c for c in rejected if c['caller'] == 'core_mmu_get_entry' and c['symbol'] == 'core_mmu_get_entry_primitive')
            self.assertEqual(wrong_callee['status'], 'callee-body-differs')
        with self.assertRaises(AssertionError):
            module.audit(BUILD, b'invalid reference')


if __name__ == '__main__':
    unittest.main()
