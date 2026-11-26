"""Own admission sequence with fake lookup/ranking; no native or device calls."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]


class BucketAdmissionTests(unittest.TestCase):
    def test_transactional_admission_and_raw_only_replay(self):
        with tempfile.TemporaryDirectory(prefix='admit-flow-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'admit-flow'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    build = subprocess.run([
                        'xcrun', 'clang++', '-std=c++11', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-I', str(PROJECT / 'Modules/HealthSupport/Core'),
                        str(HERE / 'bucket_admission_tests.cpp'), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(build.returncode, 0, build.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('raw admission execution', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
