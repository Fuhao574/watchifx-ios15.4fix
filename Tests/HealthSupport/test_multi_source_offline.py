"""Own finite multi transition with explicitly ordered synthetic pending items."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]


class MultiSourceTests(unittest.TestCase):
    def test_ordered_multi_state_transition(self):
        with tempfile.TemporaryDirectory(prefix='multi-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'multi'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    build = subprocess.run([
                        'xcrun', 'clang++', '-std=c++11', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-I', str(PROJECT / 'Modules/HealthSupport/Core'),
                        str(HERE / 'multi_source_tests.cpp'), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(build.returncode, 0, build.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('ordered multi advance', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
