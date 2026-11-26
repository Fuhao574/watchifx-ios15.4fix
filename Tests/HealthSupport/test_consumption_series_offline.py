"""Real series orchestration with private per-bucket mapping callback contexts."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]


class ConsumptionSeriesTests(unittest.TestCase):
    def test_per_bucket_context_and_consumption_timing(self):
        with tempfile.TemporaryDirectory(prefix='consume-series-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'series'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang++', '-std=c++11', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-I', str(PROJECT / 'Modules/HealthSupport/Core'),
                        str(HERE / 'consumption_series_tests.cpp'), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('no source prefetch/no runtime', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
