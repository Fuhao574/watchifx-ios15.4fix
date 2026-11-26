"""Existing private ABI signatures, own fake factories; no native Apple payload."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'
CORE = PROJECT / 'Modules/HealthSupport/Core'


class LegacyPeriodAdapterTests(unittest.TestCase):
    def test_existing_output_factory_signatures(self):
        with tempfile.TemporaryDirectory(prefix='legacy-output-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'output'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang++', '-std=c++17', '-fobjc-arc', optimization,
                        '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined', '-framework', 'Foundation',
                        '-I', str(ADAPTER), '-I', str(CORE), str(ADAPTER / 'LegacyPeriodAdapter.mm'),
                        str(HERE / 'legacy_period_adapter_tests.mm'), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('no empty finish', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
