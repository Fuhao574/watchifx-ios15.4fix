"""Module day-summary orchestration using existing signatures on own fake objects."""
from pathlib import Path
import subprocess
import tempfile
import unittest
import hashlib

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'
CORE = PROJECT / 'Modules/HealthSupport/Core'
SDK_HEADERS = Path('/Users/fuhao574/theos/sdks/iPhoneOS16.5.sdk/usr/include/c++/v1')
PINNED = {
    '__algorithm/sort.h': '33f739d139c79d5467aa69083e696b157c3d73e72711ff7552e6cd66e87d3f36',
    'unordered_set': 'ecdbcaa3576f59fed54530f686eade711563c33713f4d3fb984b704eadf344d9',
    '__hash_table': '29ca0e1a1aa04eade353b0a7d7f9f1b927580e49c2bbeefa588e96a2d707cb9a',
    '__functional/hash.h': '6789b53d861c8d444794a45bd758f5874565732f36219a4795791673ccc57725',
}


class DaySummaryAdapterTests(unittest.TestCase):
    def test_bound_day_to_legacy_summary(self):
        for name, digest in PINNED.items():
            self.assertEqual(hashlib.sha256((SDK_HEADERS / name).read_bytes()).hexdigest(), digest)
        with tempfile.TemporaryDirectory(prefix='day-summary-host-', dir=HERE) as temporary:
            work = Path(temporary)
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    objects = []
                    for name in ('DayBuilderSnapshot', 'QueryBuilderBinding', 'PeriodFinishAdapter', 'EnumerationAdapter',
                                 'SleepCalendarContext', 'CalendarBucketAdapter', 'SourceProviderAdapter', 'ProfileSleepSourceProvider'):
                        obj = work / (name + '.o')
                        built = subprocess.run([
                            'xcrun', 'clang', '-fobjc-arc', '-fobjc-arc-exceptions', optimization, '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', '-c', str(ADAPTER / (name + '.m')), '-o', str(obj),
                        ], capture_output=True, text=True, timeout=60)
                        self.assertEqual(built.returncode, 0, built.stderr)
                        objects.append(str(obj))
                    binary = work / 'summary'
                    built = subprocess.run([
                        'xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-fobjc-arc-exceptions', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fno-modules', '-nostdinc++', '-isystem', str(SDK_HEADERS),
                        '-DWATCHFIX_HEALTHSUPPORT_AUDITED_SORT_HEADER=1', '-DWATCHFIX_HEALTHSUPPORT_AUDITED_HASH_HEADERS=1',
                        '-fsanitize=address,undefined', '-framework', 'Foundation', '-I', str(ADAPTER), '-I', str(CORE),
                        *(str(ADAPTER / (name + '.mm')) for name in ('SleepSampleAdapter', 'LegacyPeriodAdapter', 'DaySummaryAdapter',
                                                                  'StableSeriesAdapter', 'DayStatisticsAdapter')),
                        str(HERE / 'day_summary_adapter_tests.mm'), *objects, '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('failure not empty success', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
