"""Actual session+policy header integration; host only, no device or root actions."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


class ActualPermitTests(unittest.TestCase):
    def test_actual_gate_and_durable_receipts(self):
        self.assertEqual((os.getuid(), os.geteuid()), (501, 501), 'no chown/root simulation')
        (ROOT/'reports').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='actual-permit-', dir=ROOT/'reports') as tmp:
            work = Path(tmp)
            (work/'roothide.h').write_text('#pragma once\nconst char *WFHostJBRoot(const char *);\n#define jbroot(p) WFHostJBRoot(p)\n')
            binary = work/'host-test'
            subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-fblocks',
                            '-I', str(work), '-I', str(ROOT/'Modules/SleepSync/Runtime/Focus'),
                            '-framework', 'Foundation', str(HERE/'test_actual_module_permit.mm'),
                            '-o', str(binary)], check=True, capture_output=True, timeout=60)
            for scenario in ('valid', 'cancel', 'closed', 'grant-replaced', 'selector-replaced',
                             'lease-expired', 'hooks-disabled', 'grant-mode', 'directory-mode',
                             'receipt-existing', 'expired'):
                with self.subTest(scenario=scenario):
                    result = subprocess.run([str(binary), scenario, str(work/scenario)],
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stdout+result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
