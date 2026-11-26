"""Own canonical-key mapping with synthetic lookup outcomes; no source API calls."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]


class SourceIdentityTests(unittest.TestCase):
    def test_native_miss_path_mapping_semantics(self):
        with tempfile.TemporaryDirectory(prefix='source-map-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'source-map'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang++', '-std=c++11', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-I', str(PROJECT / 'Modules/HealthSupport/Core'),
                        str(HERE / 'source_identity_tests.cpp'), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('bucket source mapping', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
