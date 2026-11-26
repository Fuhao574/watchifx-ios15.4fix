"""Compile OUR module core on host, not Theos or any native Apple payload."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
CORE = PROJECT / 'Modules/HealthSupport/Core'


class HealthSupportCoreTests(unittest.TestCase):
    def test_core_and_closed_gate(self):
        with tempfile.TemporaryDirectory(prefix='health-core-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'core-tests'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang++', '-std=c++11', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-I', str(CORE), str(HERE / 'core_tests.cpp'),
                        '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('HealthSupport offline core/closed gate', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
