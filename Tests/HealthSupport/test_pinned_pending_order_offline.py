"""Verify external SDK header before compiling own ordering adapter on host.

No vendored Apple algorithm, native payload execution, device access or install.
"""
from pathlib import Path
import hashlib
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
SDK_HEADERS = Path('/Users/fuhao574/theos/sdks/iPhoneOS16.5.sdk/usr/include/c++/v1')
AUDITED_SHA256 = '33f739d139c79d5467aa69083e696b157c3d73e72711ff7552e6cd66e87d3f36'


class PinnedPendingOrderTests(unittest.TestCase):
    def test_exact_external_header_and_order_adapter(self):
        self.assertEqual(hashlib.sha256((SDK_HEADERS / '__algorithm/sort.h').read_bytes()).hexdigest(), AUDITED_SHA256)
        with tempfile.TemporaryDirectory(prefix='pending-order-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'pending-order'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang++', '-std=c++17', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fno-modules', '-nostdinc++', '-isystem', str(SDK_HEADERS),
                        '-DWATCHFIX_HEALTHSUPPORT_AUDITED_SORT_HEADER=1', '-fsanitize=address,undefined',
                        '-I', str(PROJECT / 'Modules/HealthSupport/Core'), str(HERE / 'pinned_pending_order_tests.cpp'),
                        '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('pinned pending order/index-record parity', result.stdout)

    def test_unverified_header_build_is_rejected(self):
        result = subprocess.run([
            'xcrun', 'clang++', '-std=c++17', '-fsyntax-only', '-x', 'c++', '-fno-modules',
            '-nostdinc++', '-isystem', str(SDK_HEADERS), '-I', str(PROJECT / 'Modules/HealthSupport/Core'), '-',
        ], input='#include "PinnedSleepPendingOrder.hpp"\n', capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('explicit audited SDK sort header verification', result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
