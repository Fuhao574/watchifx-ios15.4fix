"""Own finite raw admission planning on synthetic intervals, never native code."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]


class RawAdmissionTests(unittest.TestCase):
    def test_two_split_plan_and_raw_carry(self):
        with tempfile.TemporaryDirectory(prefix='admission-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'admission'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang++', '-std=c++11', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-I', str(PROJECT / 'Modules/HealthSupport/Core'),
                        str(HERE / 'raw_admission_tests.cpp'), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('raw bucket admission', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
