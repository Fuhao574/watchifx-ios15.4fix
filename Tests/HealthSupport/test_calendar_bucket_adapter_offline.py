"""Compile adapter against own collection fixture; never loads HealthKit."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'
MAIN = r'''
#import "CalendarBucketAdapter.h"
#include <assert.h>
static NSUInteger calls;
@interface FakeCollection : NSObject
@property(nonatomic,strong) NSArray *items;
@property(nonatomic) int64_t first;
@property(nonatomic) BOOL shouldThrow;
- (NSDateInterval *)dateIntervalAtIndex:(int64_t)index;
@end
@implementation FakeCollection
- (NSDateInterval *)dateIntervalAtIndex:(int64_t)index {
    ++calls;
    if(self.shouldThrow) @throw [NSException exceptionWithName:@"Fixture" reason:nil userInfo:nil];
    return self.items[(NSUInteger)(index - self.first)];
}
@end
@interface DerivedCollection : FakeCollection @end
@implementation DerivedCollection @end
@interface BadABICollection : NSObject
- (NSDateInterval *)dateIntervalAtIndex:(int)index;
@end
@implementation BadABICollection
- (NSDateInterval *)dateIntervalAtIndex:(int)index { (void)index; ++calls; return nil; }
@end
@interface TypePretender : NSObject
- (NSDate *)startDate;
- (NSDate *)endDate;
@end
@implementation TypePretender
- (BOOL)isKindOfClass:(Class)cls { (void)cls; return YES; }
- (NSDate *)startDate { return [NSDate dateWithTimeIntervalSinceReferenceDate:0]; }
- (NSDate *)endDate { return [NSDate dateWithTimeIntervalSinceReferenceDate:60]; }
@end
@interface LyingDate : NSDate
@property(nonatomic) NSTimeInterval value;
@end
@implementation LyingDate
- (NSTimeInterval)timeIntervalSinceReferenceDate { return self.value; }
- (BOOL)isEqualToDate:(NSDate *)other { (void)other; return YES; }
@end
@interface CustomInterval : NSDateInterval
@property(nonatomic,strong) NSDate *first,*last;
@end
@implementation CustomInterval
- (NSDate *)startDate { return self.first; }
- (NSDate *)endDate { return self.last; }
@end
static NSDateInterval *interval(double start,double end) {
    return [[NSDateInterval alloc] initWithStartDate:[NSDate dateWithTimeIntervalSinceReferenceDate:start]
        endDate:[NSDate dateWithTimeIntervalSinceReferenceDate:end]];
}
int main(void) {
    @autoreleasepool {
        FakeCollection *collection=[FakeCollection new];collection.first=-2;
        collection.items=@[interval(-100, -39), interval(-39, 21), interval(21, 83)];
        WFHSCalendarBucketAttempt *attempt=WFHSCollectCalendarBuckets(collection,FakeCollection.class,-2,3,10);
        assert(attempt.status==WFHSCalendarBucketComplete&&attempt.intervals.count==3&&calls==3);
        assert(attempt.intervals[0]==collection.items[0]&&attempt.intervals[2]==collection.items[2]);
        assert([attempt.intervals[2] duration]==62); // no fixed60-second rewrite
        const NSUInteger prior=calls;
        assert(WFHSCollectCalendarBuckets(collection,FakeCollection.class,INT64_MAX,2,10).status==WFHSCalendarBucketInvalidRange);
        assert(WFHSCollectCalendarBuckets(collection,FakeCollection.class,0,0,10).status==WFHSCalendarBucketInvalidRange);
        assert(WFHSCollectCalendarBuckets(collection,FakeCollection.class,0,3,2).status==WFHSCalendarBucketInvalidRange);
        assert(calls==prior);
        DerivedCollection *derived=[DerivedCollection new];derived.items=collection.items;derived.first=-2;
        assert(WFHSCollectCalendarBuckets(derived,FakeCollection.class,-2,3,10).status==WFHSCalendarBucketUnverified);
        assert(WFHSCollectCalendarBuckets([BadABICollection new],BadABICollection.class,0,1,10).status==WFHSCalendarBucketUnverified);
        assert(calls==prior);
        collection.items=@[interval(0,60), interval(61,120)];collection.first=0;
        attempt=WFHSCollectCalendarBuckets(collection,FakeCollection.class,0,2,10);
        assert(attempt.status==WFHSCalendarBucketInvalidNativeResult&&!attempt.intervals);
        collection.items=@[interval(0,60), interval(59,120)];
        assert(WFHSCollectCalendarBuckets(collection,FakeCollection.class,0,2,10).status==WFHSCalendarBucketInvalidNativeResult);
        collection.items=@[interval(0,60), [NSObject new]];
        assert(WFHSCollectCalendarBuckets(collection,FakeCollection.class,0,2,10).status==WFHSCalendarBucketInvalidNativeResult);
        collection.items=@[[TypePretender new]];
        assert(WFHSCollectCalendarBuckets(collection,FakeCollection.class,0,1,10).status==WFHSCalendarBucketInvalidNativeResult);
        LyingDate *start=[LyingDate new],*end=[LyingDate new];start.value=0;end.value=60;
        CustomInterval *custom=[CustomInterval new];custom.first=start;custom.last=end;
        collection.items=@[custom,interval(61,120)];
        assert(WFHSCollectCalendarBuckets(collection,FakeCollection.class,0,2,10).status==WFHSCalendarBucketInvalidNativeResult);
        collection.items=@[interval(0,60)];
        collection.shouldThrow=YES;
        attempt=WFHSCollectCalendarBuckets(collection,FakeCollection.class,0,1,10);
        assert(attempt&&attempt.status==WFHSCalendarBucketCandidateException&&!attempt.intervals);
        puts("PASS calendar collection adapter/explicit indexes/nonuniform boundaries/no HealthKit");
    }
    return 0;
}
'''


class CalendarAdapterTests(unittest.TestCase):
    def test_own_collection_fixture(self):
        with tempfile.TemporaryDirectory(prefix='calendar-host-', dir=HERE) as temporary:
            work = Path(temporary)
            source, binary = work / 'main.m', work / 'calendar'
            source.write_text(MAIN)
            built = subprocess.run([
                'xcrun', 'clang', '-fobjc-arc', '-O2', '-Wall', '-Wextra', '-Werror',
                '-fsanitize=address,undefined', '-framework', 'Foundation', '-I', str(ADAPTER),
                str(ADAPTER / 'CalendarBucketAdapter.m'), str(source), '-o', str(binary),
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('no HealthKit', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
