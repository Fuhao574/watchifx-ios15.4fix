"""Only own day-builder-shaped fields, no real private object/health read."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'
MAIN = r'''
#import "DayBuilderSnapshot.h"
#include <assert.h>
@interface HKCalendarCache : NSObject @end
@implementation HKCalendarCache @end
@interface FakeDayBuilder : NSObject {
@public
 NSDateInterval *_dateInterval;
 HKCalendarCache *_calendarCache;
 NSMutableArray *_sleepAnalysisSamples,*_sleepScheduleSamples,*_sleepDurationGoalSamples;
 int64_t _morningIndex;
 uint64_t _weekday;
}
@end
@implementation FakeDayBuilder @end
@interface OtherBuilder : FakeDayBuilder @end
@implementation OtherBuilder @end
int main(void) {
 @autoreleasepool {
  FakeDayBuilder *builder=[FakeDayBuilder new];
  builder->_dateInterval=[[NSDateInterval alloc]initWithStartDate:[NSDate dateWithTimeIntervalSinceReferenceDate:0] duration:86400];
  builder->_calendarCache=[HKCalendarCache new];
  builder->_sleepAnalysisSamples=[NSMutableArray arrayWithObject:[NSObject new]];
  builder->_sleepScheduleSamples=[NSMutableArray arrayWithObject:[NSObject new]];
  builder->_sleepDurationGoalSamples=[NSMutableArray array];builder->_morningIndex=-123;builder->_weekday=4;
  WFHSDaySnapshot *snapshot=WFHSReadDayBuilderSnapshot(builder,FakeDayBuilder.class,HKCalendarCache.class,10);
  assert(snapshot.status==WFHSDaySnapshotComplete&&snapshot.morningIndex==-123&&snapshot.weekday==4);
  assert(snapshot.dateInterval==builder->_dateInterval&&snapshot.calendarCache==builder->_calendarCache);
  assert(snapshot.sleepAnalysisSamples[0]==builder->_sleepAnalysisSamples[0]);
  [builder->_sleepAnalysisSamples removeAllObjects];assert(snapshot.sleepAnalysisSamples.count==1);
  snapshot=WFHSReadDayBuilderSnapshot(builder,FakeDayBuilder.class,HKCalendarCache.class,1);
  assert(snapshot.status==WFHSDaySnapshotComplete);
  [builder->_sleepAnalysisSamples addObject:[NSObject new]];
  snapshot=WFHSReadDayBuilderSnapshot(builder,FakeDayBuilder.class,HKCalendarCache.class,1);
  assert(snapshot.status==WFHSDaySnapshotResourceLimit&&!snapshot.sleepAnalysisSamples);
  snapshot=WFHSReadDayBuilderSnapshot([OtherBuilder new],FakeDayBuilder.class,HKCalendarCache.class,10);
  assert(snapshot.status==WFHSDaySnapshotUnverified&&!snapshot.dateInterval);
  builder->_dateInterval=[[NSDateInterval alloc]initWithStartDate:[NSDate dateWithTimeIntervalSinceReferenceDate:0] duration:0];
  snapshot=WFHSReadDayBuilderSnapshot(builder,FakeDayBuilder.class,HKCalendarCache.class,10);
  assert(snapshot.status==WFHSDaySnapshotInvalidValue&&!snapshot.dateInterval&&!snapshot.calendarCache&&
         !snapshot.sleepAnalysisSamples&&!snapshot.sleepScheduleSamples&&!snapshot.sleepDurationGoalSamples);
  puts("PASS actual day-builder field names/runtime offsets/original context/no init replay");
 }
}
'''


class DayBuilderSnapshotTests(unittest.TestCase):
    def test_exact_declared_own_fields(self):
        with tempfile.TemporaryDirectory(prefix='day-snapshot-host-', dir=HERE) as temporary:
            work = Path(temporary)
            source, binary = work / 'main.m', work / 'snapshot'
            source.write_text(MAIN)
            built = subprocess.run([
                'xcrun', 'clang', '-fobjc-arc', '-O2', '-Wall', '-Wextra', '-Werror',
                '-fsanitize=address,undefined', '-framework', 'Foundation', '-I', str(ADAPTER),
                str(ADAPTER / 'DayBuilderSnapshot.m'), str(source), '-o', str(binary),
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('no init replay', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
