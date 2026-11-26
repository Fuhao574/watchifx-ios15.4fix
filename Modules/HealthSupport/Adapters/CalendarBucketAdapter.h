#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WFHSCalendarBucketStatus) {
    WFHSCalendarBucketUnverified = 0,
    WFHSCalendarBucketComplete,
    WFHSCalendarBucketInvalidRange,
    WFHSCalendarBucketInvalidNativeResult,
    WFHSCalendarBucketCandidateException
};

@interface WFHSCalendarBucketAttempt : NSObject
@property(nonatomic,readonly) WFHSCalendarBucketStatus status;
// Complete-only container; failure never masquerades as a normal empty array.
@property(nonatomic,strong,readonly,nullable) NSArray<NSDateInterval *> *intervals;
@end

// OFFLINE adapter under development, no class lookup/framework loading/hooks.
// Caller provides a valid exact collection object and independently verifies
// build/image/method owner/IMP/nonconcurrency. This checks existing method ABI
// only. It does not establish any of those runtime prerequisites.
// The collection must already contain the audited native anchor/components;
// this adapter never substitutes index*60, +86400, UTC or the current timezone.
// Returned intervals are strongly held, NOT deeply frozen. Value objects and
// their getters must remain stable through downstream bounds conversion.
// Attempt allocation occurs outside the candidate exception boundary; this is
// not a universal allocation/signal/invalid-pointer recovery API.
FOUNDATION_EXPORT WFHSCalendarBucketAttempt *WFHSCollectCalendarBuckets(
    id collection, Class auditedCollectionClass, int64_t firstIndex,
    NSUInteger count, NSUInteger maximumBuckets);

NS_ASSUME_NONNULL_END
