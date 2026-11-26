"""Own native-signature factories, real Foundation calendars; no HealthKit."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'
MAIN = r'''
#import "SleepCalendarContext.h"
#include <assert.h>
static NSMutableArray *events;
static NSCalendar *anchorCalendar,*cacheCalendar;
static NSDate *expectedAnchor;
static NSArray *boundaries;
static NSInteger seenSeconds;
static NSUInteger indexCalls;
static BOOL omitIndex;
@interface CalendarFactory : NSObject
+ (NSCalendar *)hk_gregorianCalendar;
@end
@implementation CalendarFactory
+ (NSCalendar *)hk_gregorianCalendar{[events addObject:@"gregorian"];return anchorCalendar;}
@end
@interface DateFactory : NSObject
+ (NSDate *)hk_sleepDayStartForMorningIndex:(int64_t)index calendar:(NSCalendar *)calendar;
@end
@implementation DateFactory
+ (NSDate *)hk_sleepDayStartForMorningIndex:(int64_t)index calendar:(NSCalendar *)calendar {
 assert(index==42&&calendar==anchorCalendar);[events addObject:@"anchor"];return expectedAnchor;
}
@end
@interface CalendarCache : NSObject
- (NSCalendar *)currentCalendar;
@end
@implementation CalendarCache
- (NSCalendar *)currentCalendar{[events addObject:@"current"];return cacheCalendar;}
@end
@interface ContextCollection : NSObject
- (instancetype)initWithAnchorDate:(NSDate *)anchor intervalComponents:(NSDateComponents *)components;
- (NSDateInterval *)dateIntervalContainingDate:(NSDate *)date index:(int64_t *)index;
- (NSDateInterval *)dateIntervalAtIndex:(int64_t)index;
@end
@implementation ContextCollection
- (instancetype)initWithAnchorDate:(NSDate *)anchor intervalComponents:(NSDateComponents *)components {
 assert(anchor==expectedAnchor&&[components.calendar isEqual:cacheCalendar]);seenSeconds=components.second;
 [events addObject:@"collection"];return [super init];
}
- (NSDateInterval *)dateIntervalContainingDate:(NSDate *)date index:(int64_t *)index {
 assert(date.timeIntervalSinceReferenceDate==10);if(!omitIndex)*index=-2;return boundaries[0];
}
- (NSDateInterval *)dateIntervalAtIndex:(int64_t)index {++indexCalls;return boundaries[(NSUInteger)(index+2)];}
@end
static NSDateInterval *interval(double s,double e) {
 return [[NSDateInterval alloc]initWithStartDate:[NSDate dateWithTimeIntervalSinceReferenceDate:s]
    endDate:[NSDate dateWithTimeIntervalSinceReferenceDate:e]];
}
static WFHSSleepCalendarContext *make(CalendarCache *cache,NSDateInterval *range,NSUInteger limit) {
 return WFHSCreateSleepCalendarContext(42,cache,CalendarCache.class,DateFactory.class,CalendarFactory.class,
    ContextCollection.class,60,range,limit);
}
int main(void) {
 @autoreleasepool {
  events=[NSMutableArray array];anchorCalendar=[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
  anchorCalendar.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];
  cacheCalendar=[anchorCalendar copy];cacheCalendar.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:3600];
  expectedAnchor=[NSDate dateWithTimeIntervalSinceReferenceDate:-1000];
  boundaries=@[interval(0,61),interval(61,121),interval(121,182)];
  CalendarCache *cache=[CalendarCache new];
  WFHSSleepCalendarContext *result=make(cache,interval(10,180),10);
  assert(result.status==WFHSSleepCalendarComplete&&result.collection&&result.intervals.count==3);
  assert(result.firstIndex==-2&&result.anchor==expectedAnchor&&result.calendar==cacheCalendar&&seenSeconds==60);
  assert(([events isEqual:@[@"gregorian",@"anchor",@"current",@"collection"]]));
  assert(result.intervals[0].startDate.timeIntervalSinceReferenceDate==0&&result.intervals[2].endDate.timeIntervalSinceReferenceDate==182);
  indexCalls=0;
  result=make(cache,interval(10,180),2);assert(result.status==WFHSSleepCalendarLimit&&!result.collection&&!result.intervals&&indexCalls==1);
  indexCalls=0;
  result=make(cache,interval(10,180),1);assert(result.status==WFHSSleepCalendarLimit&&indexCalls==0);
  omitIndex=YES;
  result=make(cache,interval(10,60),10);assert(result.status==WFHSSleepCalendarInvalidResult&&!result.collection);
  omitIndex=NO;
  boundaries=@[interval(0,61),interval(62,121),interval(121,182)];
  result=make(cache,interval(10,180),10);assert(result.status==WFHSSleepCalendarInvalidResult&&!result.intervals);
  boundaries=@[interval(11,61)];
  result=make(cache,interval(10,60),10);assert(result.status==WFHSSleepCalendarInvalidResult);
  result=make(cache,interval(10,10),10);assert(result.status==WFHSSleepCalendarInvalidInput&&!result.collection);
  puts("PASS actual calendar constructor sequence/native anchor/nonuniform full buckets/no fixed day or clipping");
 }
}
'''


class SleepCalendarContextTests(unittest.TestCase):
    def test_actual_constructor_sequence(self):
        with tempfile.TemporaryDirectory(prefix='calendar-context-host-', dir=HERE) as temporary:
            work = Path(temporary)
            source, binary = work / 'main.m', work / 'calendar'
            source.write_text(MAIN)
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang', '-fobjc-arc', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-framework', 'Foundation', '-I', str(ADAPTER),
                        str(ADAPTER / 'SleepCalendarContext.m'), str(source), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('no fixed day or clipping', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
