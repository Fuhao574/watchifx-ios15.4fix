"""Own bounded bucket driver; fake explicit ordering, no native sort/calendar."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]


class BucketAdvanceTests(unittest.TestCase):
    def test_bounded_dispatch_and_transactional_outputs(self):
        with tempfile.TemporaryDirectory(prefix='bucket-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'bucket'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    build = subprocess.run([
                        'xcrun', 'clang++', '-std=c++11', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-I', str(PROJECT / 'Modules/HealthSupport/Core'),
                        str(HERE / 'bucket_advance_tests.cpp'), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(build.returncode, 0, build.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('bounded bucket orchestration', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
