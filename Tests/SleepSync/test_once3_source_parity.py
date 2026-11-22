"""Pin the proven protocol core without needing private research inputs.

Expected hashes are the retained once3 source hashes. Only diagnostic naming is
normalized; this does not rewrite production code or claim device equivalence.
"""
from pathlib import Path
import hashlib
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / 'Modules/SleepSync/Runtime'


class Once3ParityTests(unittest.TestCase):
    def test_sleep_conversion_is_the_exact_once3_source(self):
        for name, expected in {
            'FrozenConverter.xm': '504921bd50c3efa8be9ef373f4467ad3c8a78c7f1c8e6c431ed679cc0da80fd2',
            'FocusWireConverter.h': '0176c1a51515399d915b27eb71576c498be8a15834a4872636cd56445306aa18',
            'SleepReturnObservation.h': '5b0422b95d6d58285d9b28094b9f9d22990ae463c2824ea028375687a33e2e79',
        }.items():
            with self.subTest(name=name):
                self.assertEqual(hashlib.sha256((RUNTIME/'Focus'/name).read_bytes()).hexdigest(), expected)

    def test_send_and_ack_wrappers_differ_only_by_diagnostic_labels(self):
        source = (RUNTIME/'Focus/FrozenFocus.xm').read_text()
        source = source.replace('SLEEPMODULE1', 'SLEEPONCE3').replace('sleep-module1', 'sleep-once3')
        self.assertEqual(hashlib.sha256(source.encode()).hexdigest(),
                         '7d6d1d8a7167745b166f80df4f86b4a94aa4ddca39e10420df3f88c9b3674abe')

    def test_identity_clone_and_native_contract_are_unchanged(self):
        for name, expected in {
            'NeutralCopy.h': 'f8df3578495c28801031c191c0aec8c7efbeb94f48ace86716bd046189e5b67a',
            'ExecutableGate.h': 'd0f1d5b9d505000c2055e1cbbe86fe5b0e2d9fc8b0de1cbb0f11e972ce1800ad',
        }.items():
            with self.subTest(name=name):
                self.assertEqual(hashlib.sha256((RUNTIME/'Identity'/name).read_bytes()).hexdigest(), expected)


if __name__ == '__main__':
    unittest.main(verbosity=2)
