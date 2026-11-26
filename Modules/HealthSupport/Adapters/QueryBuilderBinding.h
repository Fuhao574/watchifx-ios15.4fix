#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@class WFHSQueryBinding;
@interface WFHSBoundDayContext : NSObject
// Immediate-use snapshot, NOT a revocable authorization capability. Consume only
// within the current synchronous exclusive create, before matching end; never
// cache or pass across threads. Weak zeroing reflects object death, not end or
// invalidate. Native exclusivity is caller-proven, not supplied by registry lock.
@property(nonatomic,weak,readonly,nullable) id profile;
@property(nonatomic,weak,readonly,nullable) id calendarCache;
@property(nonatomic,readonly) uint64_t generation;
@end

// Offline association implementation, NO hooks or caller/IMP verification.
// All inputs must be valid objects from the separately verified query-server
// fresh-cache -> enumerator -> native factory path. Constructing this object is
// NOT proof a cache is fresh or its creator is that native caller. Runtime must
// install/retain it on actual objects, invalidate conflicts and cover init reuse.
// begin/end must be synchronously paired. Operation wrappers must use the scoped
// end below; unscoped end is for the independently exclusive owner only.
// Attempt allocation is not universal OOM/signal recovery.
@interface WFHSQueryBinding : NSObject
- (nullable instancetype)initWithActualEnumerator:(id)enumerator profile:(id)profile
    freshCalendarCache:(id)cache maximumBuilders:(NSUInteger)maximumBuilders;
- (BOOL)beginEnumerationFor:(id)enumerator actualProfile:(id)profile actualCache:(id)cache;
- (BOOL)bindActualReturnedBuilder:(nullable id)builder initializationCache:(nullable id)cache
    verifiedFactoryForThisEnumeration:(BOOL)verifiedFactory;
- (nullable WFHSBoundDayContext *)contextForBuilder:(id)builder actualCache:(id)cache;
// Synchronous operation identity only. Zero when inactive/invalid/dead. This is
// not an authorization token, native lock, or permission to cross threads.
- (uint64_t)activeEnumerationGeneration;
// Ends only this still-active generation; stale/zero tokens do not close or
// invalidate a later operation. Not a native concurrency/ownership guarantee.
- (BOOL)endEnumerationForGeneration:(uint64_t)generation;
- (void)endEnumeration;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
