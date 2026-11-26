"""Own raw-to-series orchestration with stable fake sources/calendar boundaries."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]


class StableSeriesTests(unittest.TestCase):
    def test_finite_stable_source_series(self):
        with tempfile.TemporaryDirectory(prefix='series-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'series'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    build = subprocess.run([
                        'xcrun', 'clang++', '-std=c++11', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-I', str(PROJECT / 'Modules/HealthSupport/Core'),
                        str(HERE / 'stable_series_tests.cpp'), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(build.returncode, 0, build.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('stable-source series', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
