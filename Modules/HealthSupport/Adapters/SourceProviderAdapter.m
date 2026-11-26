#import "SourceProviderAdapter.h"
#import "RuntimeTypeChecks.h"
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

@protocol WFHSSourceProvider
- (NSArray<NSNumber *> *)orderedSourceIDsWithUnorderedIDs:(NSArray<NSNumber *> *)ids;
- (nullable id)sourceForSourceID:(int64_t)source;
@end
@protocol WFHSSourceObject
- (nullable NSString *)bundleIdentifier;
@end

@interface WFHSSourceOrderAttempt ()
@property(nonatomic,readwrite) WFHSSourceProviderStatus status;
@property(nonatomic,strong,readwrite,nullable) NSArray<NSNumber *> *orderedSourceIDs;
@end
@implementation WFHSSourceOrderAttempt @end
@interface WFHSBundleLookupAttempt ()
@property(nonatomic,readwrite) WFHSSourceProviderStatus status;
// Store the already validated copy; never invoke a second virtual copy here.
@property(nonatomic,strong,readwrite,nullable) NSString *bundleIdentifier;
@end
@implementation WFHSBundleLookupAttempt @end

static BOOL WFHSExistingABI(Class cls, SEL selector, const char *expected) {
    // Bounded explicit superclass search avoids requesting a missing selector's
    // dynamic resolution. Only static non-unloadable audited classes are allowed.
    Class seen[64]; unsigned depth = 0;
    while (cls && depth < 64) {
        for (unsigned i = 0; i < depth; ++i) if (seen[i] == cls) return NO;
        seen[depth++] = cls;
        unsigned count = 0; Method *methods = class_copyMethodList(cls, &count);
        NSUInteger matches = 0; BOOL valid = NO;
        for (unsigned i = 0; i < count; ++i) if (sel_isEqual(method_getName(methods[i]), selector)) {
            ++matches;
            const char *actual = method_getTypeEncoding(methods[i]);
            valid = actual && !strcmp(actual, expected);
        }
        free(methods);
        if (matches) return matches == 1 && valid;
        cls = class_getSuperclass(cls);
    }
    return NO;
}

static BOOL WFHSReadSignedSourceID(id number, int64_t *value) {
    if (!WFHSActuallyInheritsFrom(number, NSNumber.class)) return NO;
    // Do not truncate floating-point IDs or accept oversized unsigned values.
    // Exact Foundation class/method provenance remains an adapter prerequisite.
    const char *type = [number objCType];
    if (!type || !type[0] || !strchr("csilqCSILQ", type[0]) || type[1]) return NO;
    if (strchr("CSILQ", type[0]) && [number unsignedLongLongValue] > INT64_MAX) return NO;
    *value = [number longLongValue];
    return YES;
}

WFHSSourceOrderAttempt *WFHSOrderRegisteredSourceIDs(id provider, Class auditedProviderClass,
                                                    NSArray<NSNumber *> *registeredSourceIDs,
                                                    NSUInteger maximumSources) {
    WFHSSourceOrderAttempt *attempt = [WFHSSourceOrderAttempt new];
    @try {
        if (!auditedProviderClass || object_getClass(provider) != auditedProviderClass ||
            !WFHSExistingABI(auditedProviderClass, @selector(orderedSourceIDsWithUnorderedIDs:), "@24@0:8@16")) return attempt;
        if (!maximumSources || !WFHSActuallyInheritsFrom(registeredSourceIDs, NSArray.class) ||
            registeredSourceIDs.count > maximumSources) {
            attempt.status = WFHSSourceProviderInvalidInput; return attempt;
        }
        NSMutableSet<NSNumber *> *expected = [NSMutableSet setWithCapacity:registeredSourceIDs.count];
        if (!expected) { attempt.status = WFHSSourceProviderInvalidNativeResult; return attempt; }
        for (id number in registeredSourceIDs) {
            int64_t source;
            if (!WFHSReadSignedSourceID(number, &source) || [expected containsObject:@(source)]) {
                attempt.status = WFHSSourceProviderInvalidInput; return attempt;
            }
            [expected addObject:@(source)];
        }
        // Independent read-only container prevents provider in-place mutation
        // from changing the identity baseline used for returned membership checks.
        NSArray *input = [[NSArray alloc] initWithArray:registeredSourceIDs];
        if (!WFHSActuallyInheritsFrom(input, NSArray.class) || input.count != expected.count) {
            attempt.status = WFHSSourceProviderInvalidNativeResult; return attempt;
        }
        id rawResult = [(id<WFHSSourceProvider>)provider orderedSourceIDsWithUnorderedIDs:input];
        if (!WFHSActuallyInheritsFrom(rawResult, NSArray.class) || [rawResult count] > expected.count) {
            attempt.status = WFHSSourceProviderInvalidNativeResult; return attempt;
        }
        NSMutableArray<NSNumber *> *ordered = [NSMutableArray arrayWithCapacity:expected.count];
        if (!ordered) { attempt.status = WFHSSourceProviderInvalidNativeResult; return attempt; }
        const NSUInteger expectedCount = [rawResult count];
        for (id number in rawResult) {
            int64_t source;
            if (!WFHSReadSignedSourceID(number, &source) || ![expected containsObject:@(source)]) {
                attempt.status = WFHSSourceProviderInvalidNativeResult; return attempt;
            }
            [expected removeObject:@(source)];
            [ordered addObject:@(source)];
        }
        NSArray *result = [[NSArray alloc] initWithArray:ordered];
        if (!WFHSActuallyInheritsFrom(result, NSArray.class) || result.count != expectedCount) {
            attempt.status = WFHSSourceProviderInvalidNativeResult; return attempt;
        }
        attempt.orderedSourceIDs = result;
        attempt.status = WFHSSourceProviderComplete;
    } @catch (NSException *candidateException) {
        (void)candidateException;
        attempt.orderedSourceIDs = nil;
        attempt.status = WFHSSourceProviderCandidateException;
    }
    return attempt;
}

WFHSBundleLookupAttempt *WFHSLookupSourceBundle(id provider, Class auditedProviderClass,
                                               int64_t sourceID, NSUInteger maximumUTF8Bytes) {
    WFHSBundleLookupAttempt *attempt = [WFHSBundleLookupAttempt new];
    @try {
        if (!auditedProviderClass || object_getClass(provider) != auditedProviderClass ||
            !WFHSExistingABI(auditedProviderClass, @selector(sourceForSourceID:), "@24@0:8q16")) return attempt;
        if (!maximumUTF8Bytes) { attempt.status = WFHSSourceProviderInvalidInput; return attempt; }
        id source = [(id<WFHSSourceProvider>)provider sourceForSourceID:sourceID];
        if (!source) { attempt.status = WFHSSourceProviderComplete; return attempt; }
        if (!WFHSExistingABI(object_getClass(source), @selector(bundleIdentifier), "@16@0:8")) return attempt;
        id bundle = [(id<WFHSSourceObject>)source bundleIdentifier];
        if (!bundle) { attempt.status = WFHSSourceProviderComplete; return attempt; }
        if (!WFHSActuallyInheritsFrom(bundle, NSString.class)) {
            attempt.status = WFHSSourceProviderInvalidNativeResult; return attempt;
        }
        // Valid UTF-8 needs at least one byte per UTF-16 code unit. Bound before
        // copying/encoding, then check the actual encoded byte count too.
        if ([bundle length] > maximumUTF8Bytes) {
            attempt.status = WFHSSourceProviderInvalidNativeResult; return attempt;
        }
        // Freeze one string result before validating it; a copy is still not
        // proof arbitrary native subclass methods are pure or threads isolated.
        id frozen = [bundle copy];
        if (!WFHSActuallyInheritsFrom(frozen, NSString.class) || [frozen length] > maximumUTF8Bytes) {
            attempt.status = WFHSSourceProviderInvalidNativeResult; return attempt;
        }
        NSData *utf8 = [frozen dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
        if (!WFHSActuallyInheritsFrom(utf8, NSData.class) || utf8.length > maximumUTF8Bytes ||
            (utf8.length && !utf8.bytes)) {
            attempt.status = WFHSSourceProviderInvalidNativeResult; return attempt;
        }
        attempt.bundleIdentifier = frozen; // nonnil empty string remains nonnil
        attempt.status = WFHSSourceProviderComplete;
    } @catch (NSException *candidateException) {
        (void)candidateException;
        attempt.bundleIdentifier = nil;
        attempt.status = WFHSSourceProviderCandidateException;
    }
    return attempt;
}
