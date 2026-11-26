#import "EnumerationAdapter.h"
#include <stdint.h>

@interface WFHSEnumerationFailure ()
@property(nonatomic,strong) WFHSQueryBinding *binding;
@property(nonatomic,strong,nullable) NSError *error;
@property(nonatomic) BOOL closed;
@property(nonatomic) uint64_t generation;
@end
@implementation WFHSEnumerationFailure
- (BOOL)allowsCandidateForBinding:(WFHSQueryBinding *)binding builder:(id)builder actualCache:(id)cache {
    if(self.closed||self.error)return NO;
    @try {
        if(binding!=self.binding||!self.generation||
           [binding activeEnumerationGeneration]!=self.generation) {
            [self recordOperationProtocolFailure];return NO;
        }
        WFHSBoundDayContext *context=[binding contextForBuilder:builder actualCache:cache];
        if(!context||context.generation!=self.generation) {
            [self recordOperationProtocolFailure];return NO;
        }
        return YES;
    } @catch(NSException *exception) {
        (void)exception;[self recordOperationProtocolFailure];return NO;
    }
}
- (BOOL)recordCandidateFailureForBuilder:(id)builder actualCache:(id)cache code:(NSInteger)code {
    if(self.closed)return NO;
    // This is synchronous, not thread-safe aggregation. A binding registry
    // lock cannot manufacture native query/handler thread provenance.
    WFHSBoundDayContext *context=[self.binding contextForBuilder:builder actualCache:cache];
    if(!context||context.generation!=self.generation||[self.binding activeEnumerationGeneration]!=self.generation)return NO;
    if(!self.error)self.error=[NSError errorWithDomain:@"WatchFix.HealthSupport.SleepEnumeration"
        code:code userInfo:nil];
    return YES;
}
- (void)recordOperationProtocolFailure {
    if(!self.closed&&!self.error)self.error=[NSError errorWithDomain:@"WatchFix.HealthSupport.SleepEnumeration"
        code:1 userInfo:nil];
}
@end

static BOOL WFHSFailEnumeration(NSError * __autoreleasing *error,NSInteger code) {
    if(error)*error=[NSError errorWithDomain:@"WatchFix.HealthSupport.SleepEnumeration" code:code userInfo:nil];
    return NO;
}

BOOL WFHSEnumerateBoundSleepSummaries(WFHSQueryBinding *binding,id enumerator,id profile,id calendarCache,
    int64_t rangeStart,int64_t rangeDuration,NSUInteger maximumDays,NSError * __autoreleasing *error,
    WFHSSleepSummaryHandler handler,WFHSOriginalSleepEnumeration original) {
    // Native treats {0,0} and nonpositive duration specially, with potentially
    // extreme close-day endpoints. Do not enter that branch then hope nil can
    // safely drain it. No range rewrite/anchor modification is performed.
    if(!binding||!enumerator||!profile||!calendarCache||!handler||!original||!maximumDays||
       rangeDuration<=0||(uint64_t)rangeDuration>maximumDays||rangeStart==INT64_MIN||
       rangeStart>INT64_MAX-rangeDuration)return WFHSFailEnumeration(error,2);
    WFHSEnumerationFailure *failure=[WFHSEnumerationFailure new];
    if(!failure)return WFHSFailEnumeration(error,3);
    failure.binding=binding;
    if(![binding beginEnumerationFor:enumerator actualProfile:profile actualCache:calendarCache])
        return WFHSFailEnumeration(error,1);
    failure.generation=[binding activeEnumerationGeneration];
    __block NSUInteger delivered=0;
    NSError *nativeError=nil;
    BOOL nativeSuccess=NO;
    @try {
        // No @catch wraps original OR the consumer handler: native/consumer
        // exceptions keep their identity. @finally closes explicit association.
        nativeSuccess=original(&nativeError,^(id summary,BOOL *stop) {
            if(failure.closed){if(stop)*stop=YES;return;}
            if(failure.error){if(stop)*stop=YES;return;}
            if([binding activeEnumerationGeneration]!=failure.generation||!failure.generation) {
                [failure recordOperationProtocolFailure];if(stop)*stop=YES;return;
            }
            if(!stop||!summary||delivered>=maximumDays) {
                failure.error=[NSError errorWithDomain:@"WatchFix.HealthSupport.SleepEnumeration" code:4 userInfo:nil];
                if(stop)*stop=YES;return;
            }
            ++delivered;
            handler(summary,stop); // same summary and stop pointer, same time
        },failure);
        // Ending/invalidating/reopening the binding without a create must not
        // turn this operation into success either. Prior deliveries stay made.
        if(!failure.generation||[binding activeEnumerationGeneration]!=failure.generation)
            [failure recordOperationProtocolFailure];
    } @finally {
        failure.closed=YES;
        [binding endEnumerationForGeneration:failure.generation];
    }
    // A genuine native error is not replaced by the candidate's own namespace.
    // A bare native NO cannot erase an already recorded explicit candidate error.
    if(nativeError){if(error)*error=nativeError;return NO;}
    if(failure.error){if(error)*error=failure.error;return NO;}
    if(!nativeSuccess){if(error)*error=nil;return NO;}
    if(error)*error=nil;
    return YES;
}
