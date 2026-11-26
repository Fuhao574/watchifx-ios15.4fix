#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Query-owned provider using native15.4 HDProfile managers and a real verified
// SleepAnalysis category. No category passed to a quantity factory; no global
// device priority. Weak profile matches native provider lifetime semantics.
// Supplied managers/type/source methods require independent image/IMP checks;
// this constructor only checks exact classes and existing ABI, not provenance.
// Compile ObjC callers/implementation with -fobjc-arc-exceptions: contract
// failures are caught by SourceProviderAdapter, and strong locals must clean up
// on those exception edges. No production build is supplied/enabled yet.
@interface WFHSProfileSleepSourceProvider : NSObject
- (nullable instancetype)initWithProfile:(id)profile profileClass:(Class)profileClass
    sleepCategory:(id)category categoryClass:(Class)categoryClass
    sourceOrderManagerClass:(Class)orderClass sourceManagerClass:(Class)sourceClass
    maximumSources:(NSUInteger)maximumSources;
- (NSArray<NSNumber *> *)orderedSourceIDsWithUnorderedIDs:(NSArray<NSNumber *> *)ids;
- (nullable id)sourceForSourceID:(int64_t)sourceID;
@end
NS_ASSUME_NONNULL_END
