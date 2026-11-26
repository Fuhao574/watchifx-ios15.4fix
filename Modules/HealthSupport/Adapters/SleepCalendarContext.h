#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, WFHSSleepCalendarStatus) {
    WFHSSleepCalendarUnverified, WFHSSleepCalendarComplete, WFHSSleepCalendarInvalidInput,
    WFHSSleepCalendarInvalidResult, WFHSSleepCalendarLimit, WFHSSleepCalendarCandidateException
};
@interface WFHSSleepCalendarContext : NSObject
@property(nonatomic,readonly) WFHSSleepCalendarStatus status;
@property(nonatomic,strong,readonly,nullable) id collection;
@property(nonatomic,strong,readonly,nullable) NSCalendar *calendar;
@property(nonatomic,strong,readonly,nullable) NSDate *anchor;
@property(nonatomic,strong,readonly,nullable) NSArray<NSDateInterval *> *intervals;
@property(nonatomic,readonly) int64_t firstIndex;
@end

// Construct existing15.4 collection via the audited16 sleep builder sequence.
// Supplied classes/objects MUST pass independent image/owner/IMP verification;
// these ABI checks don't establish native identity. No class discovery/hooks.
// actualDateClass provides +hk_sleepDayStartForMorningIndex:calendar:;
// actualCalendarClass provides +hk_gregorianCalendar. Native cache/currentCalendar
// and all date values must be stable for the synchronous construction/consumption.
// Coverage is explicit positive finite range, never inferred as a fixed day.
// Returns COMPLETE full collection buckets, not clipped sample/day intervals.
// Supported explicit bucketSeconds is1..86400 (adapter resource policy, not a
// native limit). INT64_MIN is reserved as an unwritten-index sentinel and rejected.
FOUNDATION_EXPORT WFHSSleepCalendarContext *WFHSCreateSleepCalendarContext(
    int64_t morningIndex, id calendarCache, Class auditedCacheClass, Class actualDateClass,
    Class actualCalendarClass, Class auditedCollectionClass, NSInteger bucketSeconds,
    NSDateInterval *coverage, NSUInteger maximumBuckets);
// Only bootstraps the collection and containing bucket for first raw.start;
// all following interval calls belong to raw carry/feed routing, not max-end hull.
FOUNDATION_EXPORT WFHSSleepCalendarContext *WFHSCreateSleepCalendarForFirstSample(
    int64_t morningIndex, id calendarCache, Class auditedCacheClass, Class actualDateClass,
    Class actualCalendarClass, Class auditedCollectionClass, NSInteger bucketSeconds, NSDate *firstStart);
NS_ASSUME_NONNULL_END
