"""Compile only OUR finite split/grid primitives, never target native code."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]


class PipelinePrimitivesTests(unittest.TestCase):
    def test_fast_math_cannot_silently_bypass_finite_checks(self):
        source = '#include "SleepStageFragments.hpp"\n#include "SleepSourceMergeAdvance.hpp"\n'
        for flag in ('-ffast-math', '-ffinite-math-only'):
            with self.subTest(flag=flag):
                result = subprocess.run([
                    'xcrun', 'clang++', '-std=c++11', flag, '-fsyntax-only', '-x', 'c++',
                    '-I', str(PROJECT / 'Modules/HealthSupport/Core'), '-',
                ], input=source, capture_output=True, text=True, timeout=30)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('HealthSupport requires finite-aware floating-point semantics', result.stderr)

    def test_finite_split_and_multi_sample_advance(self):
        with tempfile.TemporaryDirectory(prefix='pipeline-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'primitives'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    build = subprocess.run([
                        'xcrun', 'clang++', '-std=c++11', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-I', str(PROJECT / 'Modules/HealthSupport/Core'),
                        str(HERE / 'pipeline_primitives_tests.cpp'), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(build.returncode, 0, build.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('not complete source pipeline', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
