#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, WFHSPeriodFinishStatus) {
    WFHSPeriodFinishUnverified,
    WFHSPeriodFinishProtectedEmpty,
    WFHSPeriodFinishOriginalComplete,
    WFHSPeriodFinishCandidateFailed
};
@interface WFHSPeriodFinishAttempt : NSObject
@property(nonatomic,readonly) WFHSPeriodFinishStatus status;
@property(nonatomic,strong,readonly,nullable) NSArray *periods;
@end
typedef NSArray * _Nullable (^WFHSOriginalPeriodFinish)(id builder);

// EXACT narrow15.4 guard: zero accumulated periods, zero pending segments,
// nil minDate AND nil maxDate. Existing declared fields/ownership/container
// classes and native implementation must be independently audited. No hook,
// class lookup, field mutation, new period or synthesized interval here.
// If any prerequisite/copy fails, original is NOT invoked: status failure must
// reach the query bridge, not be turned into nil/empty success by a future hook.
// A matched nonempty state invokes original once OUTSIDE the candidate catch;
// original exceptions propagate unchanged. This does not protect repeat finish
// after an already flushed period; that behavior is deliberately not added.
FOUNDATION_EXPORT WFHSPeriodFinishAttempt *WFHSFinishPeriodWithEmptyGuard(
    id builder, Class auditedBuilderClass, Class auditedMutableArrayClass,
    Class auditedEmptyCopyClass, WFHSOriginalPeriodFinish original);
NS_ASSUME_NONNULL_END
