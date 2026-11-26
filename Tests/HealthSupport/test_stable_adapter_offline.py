"""Own Objective-C++ fixture integration; Foundation only, no HealthKit/device."""
from pathlib import Path
import hashlib
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'
CORE = PROJECT / 'Modules/HealthSupport/Core'
SDK_HEADERS = Path('/Users/fuhao574/theos/sdks/iPhoneOS16.5.sdk/usr/include/c++/v1')
AUDITED_SHA256 = '33f739d139c79d5467aa69083e696b157c3d73e72711ff7552e6cd66e87d3f36'
HASH_HEADERS = {
    'unordered_set': 'ecdbcaa3576f59fed54530f686eade711563c33713f4d3fb984b704eadf344d9',
    '__hash_table': '29ca0e1a1aa04eade353b0a7d7f9f1b927580e49c2bbeefa588e96a2d707cb9a',
    '__functional/hash.h': '6789b53d861c8d444794a45bd758f5874565732f36219a4795791673ccc57725',
}


class StableAdapterTests(unittest.TestCase):
    def test_calendar_provider_sort_series_integration(self):
        self.assertEqual(hashlib.sha256((SDK_HEADERS / '__algorithm/sort.h').read_bytes()).hexdigest(), AUDITED_SHA256)
        for name, digest in HASH_HEADERS.items():
            self.assertEqual(hashlib.sha256((SDK_HEADERS / name).read_bytes()).hexdigest(), digest)
        with tempfile.TemporaryDirectory(prefix='stable-adapter-host-', dir=HERE) as temporary:
            work = Path(temporary)
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    objects = []
                    for name in ('CalendarBucketAdapter', 'SourceProviderAdapter'):
                        obj = work / (name + '.o')
                        built = subprocess.run([
                            'xcrun', 'clang', '-fobjc-arc', optimization, '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', '-c', str(ADAPTER / (name + '.m')), '-o', str(obj),
                        ], capture_output=True, text=True, timeout=60)
                        self.assertEqual(built.returncode, 0, built.stderr)
                        objects.append(str(obj))
                    binary = work / 'stable-adapter'
                    built = subprocess.run([
                        'xcrun', 'clang++', '-std=c++17', '-fobjc-arc', optimization,
                        '-Wall', '-Wextra', '-Werror', '-fno-modules', '-nostdinc++', '-isystem', str(SDK_HEADERS),
                        '-DWATCHFIX_HEALTHSUPPORT_AUDITED_SORT_HEADER=1', '-fsanitize=address,undefined',
                        '-DWATCHFIX_HEALTHSUPPORT_AUDITED_HASH_HEADERS=1',
                        '-framework', 'Foundation', '-I', str(ADAPTER), '-I', str(CORE),
                        str(ADAPTER / 'StableSeriesAdapter.mm'), str(HERE / 'stable_adapter_tests.mm'),
                        str(ADAPTER / 'SleepSampleAdapter.mm'), str(ADAPTER / 'LegacyPeriodAdapter.mm'),
                        *objects, '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('failure closed/no HealthKit', result.stdout)
                    self.assertIn('sample getter objects to existing period factory signatures/raw untouched', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
