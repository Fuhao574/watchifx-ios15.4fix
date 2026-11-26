#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, WFHSSourceProviderStatus) {
    WFHSSourceProviderUnverified = 0,
    WFHSSourceProviderComplete,
    WFHSSourceProviderInvalidInput,
    WFHSSourceProviderInvalidNativeResult,
    WFHSSourceProviderCandidateException
};

@interface WFHSSourceOrderAttempt : NSObject
@property(nonatomic,readonly) WFHSSourceProviderStatus status;
// Valid preference SUBSET, possibly empty, not a filtered replacement for the
// complete registered-source vector. Calculator sorts ALL IDs using this rank.
@property(nonatomic,strong,readonly,nullable) NSArray<NSNumber *> *orderedSourceIDs;
@end

@interface WFHSBundleLookupAttempt : NSObject
@property(nonatomic,readonly) WFHSSourceProviderStatus status;
// Complete+nil is an actual native nil result, NOT missing metadata or a thrown
// candidate exception. The core must preserve relookup behavior for nil bundles.
@property(nonatomic,strong,readonly,nullable) NSString *bundleIdentifier;
@end

// Offline adapters. No provider construction, class lookup, HealthStore queries,
// hooks or image loading. Actual build/image/IMP/ownership/thread prerequisites
// must be established independently before future native use.
FOUNDATION_EXPORT WFHSSourceOrderAttempt *WFHSOrderRegisteredSourceIDs(
    id provider, Class auditedProviderClass, NSArray<NSNumber *> *registeredSourceIDs,
    NSUInteger maximumSources);

FOUNDATION_EXPORT WFHSBundleLookupAttempt *WFHSLookupSourceBundle(
    id provider, Class auditedProviderClass, int64_t sourceID, NSUInteger maximumUTF8Bytes);
NS_ASSUME_NONNULL_END
