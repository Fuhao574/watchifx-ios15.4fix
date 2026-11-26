#import <Foundation/Foundation.h>
#import "QueryBuilderBinding.h"
NS_ASSUME_NONNULL_BEGIN

@interface WFHSEnumerationFailure : NSObject
// Explicit operation-scoped create admission; call before candidate work and
// before publishing its result. Checks open/no prior failure, binding identity,
// generation and actual builder/cache association. An open operation's mismatch
// latches protocol failure; a closed channel stays closed. Synchronous only,
// neither a native lock nor authority to install hooks/cross threads.
- (BOOL)allowsCandidateForBinding:(WFHSQueryBinding *)binding builder:(id)builder actualCache:(id)cache;
// Only the actual builder bound to this explicit operation may record failure.
// Passing this object through a closure/association is integration responsibility;
// there is no current-thread/TLS attribution or implicit global active query.
- (BOOL)recordCandidateFailureForBuilder:(id)builder actualCache:(id)cache code:(NSInteger)code;
// Explicit operation-level protocol failure used when the caller cannot prove
// this create belongs to the operation. Not attributed to an unbound builder.
- (void)recordOperationProtocolFailure;
@end

typedef void (^WFHSSleepSummaryHandler)(id summary, BOOL *stop);
typedef BOOL (^WFHSOriginalSleepEnumeration)(NSError * _Nullable __autoreleasing * _Nullable error,
    WFHSSleepSummaryHandler handler, WFHSEnumerationFailure *failure);

// The native selector is -enumerateWithError:handler: (B32@0:8^@16@?24).
// failure is OUR explicit closure context, not an additional native argument.
// Prerequisites: exact native implementation/caller checked, original range
// matches start/duration below, finite bounded source enumeration, synchronous
// handler on this operation, and all relevant creates use this failure channel.
// This function does not establish any of those runtime facts or install hooks.
// Does NOT buffer prior successful days: preserves handler timing/stop semantics.
// Later candidate failure returns NO and own NSError; already delivered days
// are not recalled. Caller must honor terminal error, not success-complete.
FOUNDATION_EXPORT BOOL WFHSEnumerateBoundSleepSummaries(WFHSQueryBinding *binding,
    id enumerator, id profile, id calendarCache, int64_t rangeStart, int64_t rangeDuration,
    NSUInteger maximumDays, NSError * _Nullable __autoreleasing * _Nullable error,
    WFHSSleepSummaryHandler handler, WFHSOriginalSleepEnumeration original);
NS_ASSUME_NONNULL_END
