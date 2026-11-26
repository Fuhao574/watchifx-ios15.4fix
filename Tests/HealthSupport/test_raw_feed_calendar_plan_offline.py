"""Own raw carry routing and series integration, synthetic calendar callbacks."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]


class RawFeedCalendarPlanTests(unittest.TestCase):
    def test_first_sample_carry_and_finish(self):
        with tempfile.TemporaryDirectory(prefix='raw-calendar-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'plan'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang++', '-std=c++11', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-I', str(PROJECT / 'Modules/HealthSupport/Core'),
                        str(HERE / 'raw_feed_calendar_plan_tests.cpp'), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('no extra tail', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
