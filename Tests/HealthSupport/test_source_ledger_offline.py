"""Compile/run own source ledger with synthetic keys and fragment times only."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]


class SourceLedgerTests(unittest.TestCase):
    def test_transactional_source_reducers(self):
        with tempfile.TemporaryDirectory(prefix='ledger-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'ledger'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang++', '-std=c++11', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-I', str(PROJECT / 'Modules/HealthSupport/Core'),
                        str(HERE / 'source_ledger_tests.cpp'), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('source ledger independent reducers', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
