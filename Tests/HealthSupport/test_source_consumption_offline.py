"""Own mapping callbacks at audited consumption points; no native source queries."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]


class SourceConsumptionTests(unittest.TestCase):
    def test_consumption_points_and_staged_mapping(self):
        with tempfile.TemporaryDirectory(prefix='source-consumption-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'consume'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang++', '-std=c++11', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-I', str(PROJECT / 'Modules/HealthSupport/Core'),
                        str(HERE / 'source_consumption_tests.cpp'), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('no frozen admission key', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
