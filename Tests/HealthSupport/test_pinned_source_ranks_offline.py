"""Pin external libc++ hash headers before executing own source ranking adapter."""
from pathlib import Path
import hashlib
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
SDK_HEADERS = Path('/Users/fuhao574/theos/sdks/iPhoneOS16.5.sdk/usr/include/c++/v1')
HASH_HEADERS = {
    '__algorithm/sort.h': '33f739d139c79d5467aa69083e696b157c3d73e72711ff7552e6cd66e87d3f36',
    'unordered_set': 'ecdbcaa3576f59fed54530f686eade711563c33713f4d3fb984b704eadf344d9',
    '__hash_table': '29ca0e1a1aa04eade353b0a7d7f9f1b927580e49c2bbeefa588e96a2d707cb9a',
    '__functional/hash.h': '6789b53d861c8d444794a45bd758f5874565732f36219a4795791673ccc57725',
}


class PinnedSourceRanksTests(unittest.TestCase):
    def test_traversal_and_refresh(self):
        for name, digest in HASH_HEADERS.items():
            self.assertEqual(hashlib.sha256((SDK_HEADERS / name).read_bytes()).hexdigest(), digest)
        with tempfile.TemporaryDirectory(prefix='source-ranks-host-', dir=HERE) as temporary:
            binary = Path(temporary) / 'ranks'
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang++', '-std=c++17', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fno-modules', '-nostdinc++', '-isystem', str(SDK_HEADERS),
                        '-DWATCHFIX_HEALTHSUPPORT_AUDITED_HASH_HEADERS=1', '-fsanitize=address,undefined',
                        '-DWATCHFIX_HEALTHSUPPORT_AUDITED_SORT_HEADER=1',
                        '-I', str(PROJECT / 'Modules/HealthSupport/Core'), str(HERE / 'pinned_source_ranks_tests.cpp'),
                        '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('rank refresh only on registration growth', result.stdout)

    def test_unverified_headers_rejected(self):
        result = subprocess.run([
            'xcrun', 'clang++', '-std=c++17', '-fsyntax-only', '-x', 'c++', '-fno-modules',
            '-nostdinc++', '-isystem', str(SDK_HEADERS), '-I', str(PROJECT / 'Modules/HealthSupport/Core'), '-',
        ], input='#include "PinnedSleepSourceRanks.hpp"\n', capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('explicit audited hash header verification', result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
