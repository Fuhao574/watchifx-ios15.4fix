#import "QueryBuilderBinding.h"
#include <stdint.h>

@interface WFHSBoundDayContext ()
@property(nonatomic,weak,readwrite,nullable) id profile,calendarCache;
@property(nonatomic,readwrite) uint64_t generation;
@end
@implementation WFHSBoundDayContext @end

@interface WFHSQueryBinding ()
@property(nonatomic,weak) id enumerator,profile,cache;
@property(nonatomic,strong) NSLock *lock;
@property(nonatomic,strong) NSMapTable *builders;
@property(nonatomic) BOOL invalid,active;
@property(nonatomic) uint64_t generation;
@property(nonatomic) NSUInteger maximumBuilders;
@end

@implementation WFHSQueryBinding
- (instancetype)initWithActualEnumerator:(id)enumerator profile:(id)profile freshCalendarCache:(id)cache
    maximumBuilders:(NSUInteger)maximumBuilders {
    if(!enumerator||!profile||!cache||!maximumBuilders)return nil;
    if((self=[super init])) {
        _enumerator=enumerator;_profile=profile;_cache=cache;
        _maximumBuilders=maximumBuilders;
        _lock=[NSLock new];
        // Pointer identity only: never ask native objects to hash/isEqual:.
        // Weak keys zero on deallocation, not naked reusable address tokens.
        _builders=[[NSMapTable alloc]initWithKeyOptions:NSPointerFunctionsWeakMemory|NSPointerFunctionsObjectPointerPersonality
            valueOptions:NSPointerFunctionsStrongMemory capacity:0];
        if(!_lock||!_builders)return nil;
    }
    return self;
}
- (BOOL)beginEnumerationFor:(id)enumerator actualProfile:(id)profile actualCache:(id)cache {
    __attribute__((objc_precise_lifetime)) id recordedEnumerator=self.enumerator,recordedProfile=self.profile,recordedCache=self.cache;
    [self.lock lock];
    @try {
        if(self.invalid||self.active||!enumerator||!profile||!cache||
           recordedEnumerator!=enumerator||recordedProfile!=profile||recordedCache!=cache||self.generation==UINT64_MAX) {
            self.invalid=YES;self.active=NO;return NO;
        }
        ++self.generation;self.active=YES;return YES;
    } @catch(NSException *exception) {
        (void)exception;self.invalid=YES;self.active=NO;return NO;
    } @finally {[self.lock unlock];}
}
- (BOOL)bindActualReturnedBuilder:(id)builder initializationCache:(id)cache
    verifiedFactoryForThisEnumeration:(BOOL)verifiedFactory {
    __attribute__((objc_precise_lifetime)) id recordedProfile=self.profile,recordedCache=self.cache,recordedEnumerator=self.enumerator;
    [self.lock lock];
    @try {
        if(self.invalid||!self.active||!builder||!cache||!verifiedFactory||recordedCache!=cache||!recordedProfile||!recordedEnumerator) {
            self.invalid=YES;self.active=NO;return NO;
        }
        if([self.builders objectForKey:builder]||self.builders.count>=self.maximumBuilders) { // repeated init never silently rebinds
            self.invalid=YES;self.active=NO;return NO;
        }
        [self.builders setObject:@(self.generation) forKey:builder];
        return YES;
    } @catch(NSException *exception) {
        (void)exception;self.invalid=YES;self.active=NO;return NO;
    } @finally {[self.lock unlock];}
}
- (WFHSBoundDayContext *)contextForBuilder:(id)builder actualCache:(id)cache {
    // Allocate and retain weak-loaded profile/cache outside the registry lock;
    // context may outlive lock, not the caller-verified synchronous operation.
    WFHSBoundDayContext *result=[WFHSBoundDayContext new];
    __attribute__((objc_precise_lifetime)) id profile=self.profile,expectedCache=self.cache,enumerator=self.enumerator;
    if(!result||!profile||!expectedCache||!enumerator||!builder||!cache)return nil;
    [self.lock lock];
    @try {
        NSNumber *generation=[self.builders objectForKey:builder];
        if(self.invalid||!self.active||cache!=expectedCache||
           !generation||generation.unsignedLongLongValue!=self.generation)return nil;
        result.profile=profile;result.calendarCache=expectedCache;result.generation=self.generation;
        return result;
    } @catch(NSException *exception) {
        (void)exception;self.invalid=YES;self.active=NO;return nil;
    } @finally {[self.lock unlock];}
}
- (uint64_t)activeEnumerationGeneration {
    __attribute__((objc_precise_lifetime)) id profile=self.profile,cache=self.cache,enumerator=self.enumerator;
    if(!profile||!cache||!enumerator)return 0;
    [self.lock lock];
    @try {return !self.invalid&&self.active?self.generation:0;}
    @finally {[self.lock unlock];}
}
- (BOOL)endEnumerationForGeneration:(uint64_t)generation {
    [self.lock lock];
    @try {
        if(!generation||self.invalid||!self.active||self.generation!=generation)return NO;
        self.active=NO;return YES;
    } @finally {[self.lock unlock];}
}
- (void)endEnumeration {
    [self.lock lock];
    @try {self.active=NO;} @finally {[self.lock unlock];}
}
- (void)invalidate {
    [self.lock lock];
    @try {self.invalid=YES;self.active=NO;} @finally {[self.lock unlock];}
}
@end
