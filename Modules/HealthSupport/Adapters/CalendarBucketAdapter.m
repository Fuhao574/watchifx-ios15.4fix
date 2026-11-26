#import "CalendarBucketAdapter.h"
#import "RuntimeTypeChecks.h"
#import <objc/runtime.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

@protocol WFHSIntervalCollection
- (NSDateInterval *)dateIntervalAtIndex:(int64_t)index;
@end

@interface WFHSCalendarBucketAttempt ()
@property(nonatomic,readwrite) WFHSCalendarBucketStatus status;
@property(nonatomic,strong,readwrite,nullable) NSArray<NSDateInterval *> *intervals;
@end
@implementation WFHSCalendarBucketAttempt @end

static BOOL WFHSDeclaredIntervalGetterABI(Class cls) {
    // Enumerate declared methods, not resolver-triggering missing-method lookup.
    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSUInteger matches = 0;
    BOOL valid = NO;
    for (unsigned i = 0; i < count; ++i) {
        if (sel_isEqual(method_getName(methods[i]), @selector(dateIntervalAtIndex:))) {
            ++matches;
            const char *encoding = method_getTypeEncoding(methods[i]);
            valid = encoding && !strcmp(encoding, "@24@0:8q16");
        }
    }
    free(methods);
    return matches == 1 && valid;
}

WFHSCalendarBucketAttempt *WFHSCollectCalendarBuckets(id collection, Class auditedCollectionClass,
                                                     int64_t firstIndex, NSUInteger count,
                                                     NSUInteger maximumBuckets) {
    WFHSCalendarBucketAttempt *attempt = [WFHSCalendarBucketAttempt new];
    if (!maximumBuckets || !count || count > maximumBuckets || count - 1 > INT64_MAX ||
        firstIndex > INT64_MAX - (int64_t)(count - 1)) {
        attempt.status = WFHSCalendarBucketInvalidRange;
        return attempt;
    }
    @try {
        if (!auditedCollectionClass || object_getClass(collection) != auditedCollectionClass ||
            !WFHSDeclaredIntervalGetterABI(auditedCollectionClass)) return attempt;
        NSMutableArray<NSDateInterval *> *intervals = [NSMutableArray arrayWithCapacity:count];
        if (!intervals) { attempt.status = WFHSCalendarBucketInvalidNativeResult; return attempt; }
        BOOL hasPrevious = NO; double previousEnd = 0;
        for (NSUInteger i = 0; i < count; ++i) {
            id interval = [(id<WFHSIntervalCollection>)collection dateIntervalAtIndex:firstIndex + (int64_t)i];
            if (!WFHSActuallyInheritsFrom(interval, NSDateInterval.class)) {
                attempt.status = WFHSCalendarBucketInvalidNativeResult; return attempt;
            }
            NSDate *start = [interval startDate], *end = [interval endDate];
            if (!WFHSActuallyInheritsFrom(start, NSDate.class) || !WFHSActuallyInheritsFrom(end, NSDate.class)) {
                attempt.status = WFHSCalendarBucketInvalidNativeResult; return attempt;
            }
            const double s = start.timeIntervalSinceReferenceDate;
            const double e = end.timeIntervalSinceReferenceDate;
            // Equivalent native date endpoints must agree; never add a tolerance
            // that would silently hide gaps/overlaps in calendar collection output.
            if (!isfinite(s) || !isfinite(e) || !(e > s) || !isfinite(e - s) ||
                (hasPrevious && s != previousEnd)) {
                attempt.status = WFHSCalendarBucketInvalidNativeResult; return attempt;
            }
            [intervals addObject:interval];
            hasPrevious = YES; previousEnd = e;
        }
        NSArray *result = [[NSArray alloc] initWithArray:intervals];
        if (!WFHSActuallyInheritsFrom(result, NSArray.class) || result.count != count) {
            attempt.status = WFHSCalendarBucketInvalidNativeResult; return attempt;
        }
        attempt.intervals = result;
        attempt.status = WFHSCalendarBucketComplete;
    } @catch (NSException *candidateException) {
        // No raw exception reason/userInfo is retained; the adapter makes no
        // native query failure or data-success claim on this path.
        (void)candidateException;
        attempt.intervals = nil;
        attempt.status = WFHSCalendarBucketCandidateException;
    }
    return attempt;
}
