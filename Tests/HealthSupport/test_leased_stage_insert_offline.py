"""Real local gate + real adapter, fake insert only; no Health data or device."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'
CORE = PROJECT / 'Modules/HealthSupport/Core'


class LeasedStageInsertTests(unittest.TestCase):
    def test_gate_wraps_the_entire_original_call(self):
        with tempfile.TemporaryDirectory(prefix='leased-insert-host-', dir=HERE) as temporary:
            work = Path(temporary)
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    state = work / ('state' + optimization)
                    state.mkdir(mode=0o700)
                    obj = work / 'boundary.o'
                    built = subprocess.run([
                        'xcrun', 'clang', '-fobjc-arc', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-c', str(ADAPTER / 'StageWriteBoundary.m'), '-o', str(obj),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    binary = work / 'insert'
                    built = subprocess.run([
                        'xcrun', 'clang++', '-std=c++17', '-fobjc-arc', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-pthread', '-framework', 'Foundation',
                        '-I', str(ADAPTER), '-I', str(CORE), str(ADAPTER / 'ReceiveGate.cpp'),
                        str(ADAPTER / 'LeasedStageInsert.mm'), str(HERE / 'leased_stage_insert_tests.mm'),
                        str(obj), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary), str(state)], capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('no runtime enable', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
