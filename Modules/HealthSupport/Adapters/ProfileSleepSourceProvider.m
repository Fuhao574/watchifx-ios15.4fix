#import "ProfileSleepSourceProvider.h"
#import "RuntimeTypeChecks.h"
#include <stdlib.h>
#include <string.h>

@protocol WFHSProfileManagers
- (id)sourceOrderManager;
- (id)sourceManager;
- (NSInteger)code;
- (nullable NSArray *)orderedSourceIDsForObjectType:(id)type bundleIdentifierMapping:(nullable id)mapping
    userOrdered:(nullable BOOL *)userOrdered error:(NSError * _Nullable __autoreleasing * _Nullable)error;
- (nullable id)clientSourceForPersistentID:(NSNumber *)identifier error:(NSError * _Nullable __autoreleasing * _Nullable)error;
@end
static BOOL WFHSProfileABI(Class cls,SEL selector,const char *expected) {
    Class seen[64];unsigned depth=0;
    while(cls&&depth<64) {
        for(unsigned i=0;i<depth;++i)if(seen[i]==cls)return NO;
        seen[depth++]=cls;unsigned count=0;Method *methods=class_copyMethodList(cls,&count);unsigned matches=0;BOOL valid=NO;
        for(unsigned i=0;i<count;++i)if(sel_isEqual(method_getName(methods[i]),selector)) {
            ++matches;const char *actual=method_getTypeEncoding(methods[i]);valid=actual&&!strcmp(actual,expected);
        }
        free(methods);if(matches)return matches==1&&valid;cls=class_getSuperclass(cls);
    }
    return NO;
}
static NSNumber *WFHSCanonicalID(id value) {
    if(!WFHSActuallyInheritsFrom(value,NSNumber.class))return nil;
    const char *type=[value objCType];
    if(!type||!type[0]||type[1]||!strchr("csilqCSILQ",type[0])||
       (strchr("CSILQ",type[0])&&[value unsignedLongLongValue]>INT64_MAX))return nil;
    return @([value longLongValue]);
}
static void WFHSInvalidProviderResult(void) {
    @throw[NSException exceptionWithName:@"WFHSProviderContractFailure" reason:nil userInfo:nil];
}
@interface WFHSProfileSleepSourceProvider ()
@property(nonatomic,weak) id profile;
@property(nonatomic,strong) id category;
@property(nonatomic,assign) Class profileClass,orderClass,sourceClass;
@property(nonatomic) NSUInteger maximumSources;
@end
@implementation WFHSProfileSleepSourceProvider
- (instancetype)initWithProfile:(id)profile profileClass:(Class)profileClass sleepCategory:(id)category
    categoryClass:(Class)categoryClass sourceOrderManagerClass:(Class)orderClass sourceManagerClass:(Class)sourceClass
    maximumSources:(NSUInteger)maximumSources {
    if(!profileClass||!categoryClass||!orderClass||!sourceClass||!maximumSources||
       object_getClass(profile)!=profileClass||object_getClass(category)!=categoryClass)return nil;
    if(!WFHSProfileABI(profileClass,@selector(sourceOrderManager),"@16@0:8")||
       !WFHSProfileABI(profileClass,@selector(sourceManager),"@16@0:8")||
       !WFHSProfileABI(categoryClass,@selector(code),"q16@0:8")||
       !WFHSProfileABI(orderClass,@selector(orderedSourceIDsForObjectType:bundleIdentifierMapping:userOrdered:error:),"@48@0:8@16@24^B32^@40")||
       !WFHSProfileABI(sourceClass,@selector(clientSourceForPersistentID:error:),"@32@0:8@16^@24"))return nil;
    if([(id<WFHSProfileManagers>)category code]!=63)return nil;
    if((self=[super init])) {
        _profile=profile;_category=category;_profileClass=profileClass;_orderClass=orderClass;_sourceClass=sourceClass;
        _maximumSources=maximumSources;
    }
    return self;
}
- (NSArray<NSNumber *> *)orderedSourceIDsWithUnorderedIDs:(NSArray<NSNumber *> *)ids {
    if(!WFHSActuallyInheritsFrom(ids,NSArray.class)||ids.count>self.maximumSources)WFHSInvalidProviderResult();
    NSMutableSet *membership=[NSMutableSet setWithCapacity:ids.count];
    if(!membership)WFHSInvalidProviderResult();
    for(id value in ids) {
        NSNumber *number=WFHSCanonicalID(value);
        if(!number||[membership containsObject:number])WFHSInvalidProviderResult();
        [membership addObject:number];
    }
    __attribute__((objc_precise_lifetime)) id profile=self.profile;
    // Actual weak-profile disappearance produces nil manager/native fallback.
    // Invalid nonnil manager/class is NOT downgraded to that legitimate nil.
    if(profile&&object_getClass(profile)!=self.profileClass)WFHSInvalidProviderResult();
    id manager=[(id<WFHSProfileManagers>)profile sourceOrderManager];
    if(manager&&object_getClass(manager)!=self.orderClass)WFHSInvalidProviderResult();
    NSError *error=nil;
    id native=[(id<WFHSProfileManagers>)manager orderedSourceIDsForObjectType:self.category
        bundleIdentifierMapping:nil userOrdered:NULL error:&error];
    (void)error; // Native15.4 uses nil result, NOT NSError presence, as fallback condition.
    if(!native) {
        NSArray *copy=[[NSArray alloc]initWithArray:ids];if(!copy||copy.count!=ids.count)WFHSInvalidProviderResult();return copy;
    }
    if(!WFHSActuallyInheritsFrom(native,NSArray.class)||[native count]>self.maximumSources)WFHSInvalidProviderResult();
    NSMutableArray *filtered=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    if(!filtered||!seen)WFHSInvalidProviderResult();
    for(id value in native) {
        NSNumber *number=WFHSCanonicalID(value);if(!number)WFHSInvalidProviderResult();
        if([membership containsObject:number]) {
            if([seen containsObject:number])WFHSInvalidProviderResult();
            [seen addObject:number];[filtered addObject:number];
        }
    }
    NSArray *result=[[NSArray alloc]initWithArray:filtered];
    if(!result||result.count!=filtered.count)WFHSInvalidProviderResult();return result;
}
- (id)sourceForSourceID:(int64_t)sourceID {
    __attribute__((objc_precise_lifetime)) id profile=self.profile;
    if(profile&&object_getClass(profile)!=self.profileClass)WFHSInvalidProviderResult();
    id manager=[(id<WFHSProfileManagers>)profile sourceManager];
    if(manager&&object_getClass(manager)!=self.sourceClass)WFHSInvalidProviderResult();
    NSError *error=nil;
    id source=[(id<WFHSProfileManagers>)manager clientSourceForPersistentID:@(sourceID) error:&error];
    (void)error;return source; // real nil is not cached; caller inspects native bundle.
}
@end
