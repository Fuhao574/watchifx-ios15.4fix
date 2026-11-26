"""Real POSIX metadata writes confined to an exact self-created project test dir.

No device/Health data, installer paths, native hook or production enablement.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'


class ReceiveGateTests(unittest.TestCase):
    def test_durable_gate_and_inflight(self):
        with tempfile.TemporaryDirectory(prefix='receive-gate-host-', dir=HERE) as temporary:
            work = Path(temporary)
            binary = work / 'gate'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    state = work / ('state' + optimization)
                    state.mkdir(mode=0o700)
                    built = subprocess.run([
                        'xcrun', 'clang++', '-std=c++17', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-pthread', '-I', str(ADAPTER),
                        str(ADAPTER / 'ReceiveGate.cpp'), str(HERE / 'receive_gate_tests.cpp'), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary), str(state)], capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('corruption fails closed', result.stdout)
                    crashed = work / ('crashed' + optimization)
                    crashed.mkdir(mode=0o700)
                    for mode in ('enable-crash', 'restart-check'):
                        result = subprocess.run([str(binary), str(crashed), mode], capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, 0, result.stderr)
                    # Only files in this self-created test namespace are edited.
                    # Neither receipt nor loss of real Health samples is inferred.
                    for label, journal, marker in (
                        ('missing-marker', b'WFHS-R1\nENABLED\n', None),
                        ('bad-marker', b'WFHS-R1\nSTOPPED\n', b'bad'),
                        ('torn-header', b'WFHS', None),
                        ('unknown-record', b'WFHS-R1\nUNKNOWN\n', None),
                    ):
                        broken = work / (label + optimization)
                        broken.mkdir(mode=0o700)
                        path = broken / 'receive-journal-v1'
                        path.write_bytes(journal)
                        path.chmod(0o600)
                        if marker is not None:
                            dependency = broken / 'read-dependency-v1'
                            dependency.write_bytes(marker)
                            dependency.chmod(0o600)
                        result = subprocess.run([str(binary), str(broken), 'reject-existing'], capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(path.read_bytes(), journal)  # no truncate/repair
                    insecure = work / ('permissions' + optimization)
                    insecure.mkdir(mode=0o755)
                    result = subprocess.run([str(binary), str(insecure), 'reject-fresh'], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    linked = work / ('symlink' + optimization)
                    linked.mkdir(mode=0o700)
                    target = work / ('untouched' + optimization)
                    target.write_bytes(b'WFHS-R1\nSTOPPED\n')
                    target.chmod(0o600)
                    (linked / 'receive-journal-v1').symlink_to(target)
                    result = subprocess.run([str(binary), str(linked), 'reject-existing'], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(target.read_bytes(), b'WFHS-R1\nSTOPPED\n')
                    fifo = work / ('fifo' + optimization)
                    fifo.mkdir(mode=0o700)
                    (fifo / 'receive-journal-v1').write_bytes(b'WFHS-R1\nSTOPPED\n')
                    (fifo / 'receive-journal-v1').chmod(0o600)
                    os.mkfifo(fifo / 'read-dependency-v1', 0o600)
                    result = subprocess.run([str(binary), str(fifo), 'reject-existing'], capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    near = work / ('near-limit' + optimization)
                    near.mkdir(mode=0o700)
                    path = near / 'receive-journal-v1'
                    path.write_bytes(b'WFHS-R1\n' + b'STOPPED\n' * ((1024 * 1024 - 16) // 8))
                    path.chmod(0o600)
                    result = subprocess.run([str(binary), str(near), 'near-limit'], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
