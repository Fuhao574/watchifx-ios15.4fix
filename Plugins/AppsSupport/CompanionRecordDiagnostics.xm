#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <substrate.h>
#include <stdlib.h>
#include <string.h>
#include "utils.h"

@interface NSObject (WFReadOnlyApplicationRecord)
- (instancetype)initWithBundleIdentifier:(NSString *)bundleID allowPlaceholder:(BOOL)allowPlaceholder error:(NSError **)error;
@end

// Pass-through observers only. No guessed property access, KVC, application
// descriptions, cache writes, sequence changes, or synthetic app events.
static BOOL WFRecordABI(Method method, const char *result, NSArray<NSString *> *args) {
    if (!method || method_getNumberOfArguments(method) != args.count + 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = type && strcmp(type, result) == 0;
    free(type);
    for (NSUInteger i = 0; valid && i < args.count; i++) {
        type = method_copyArgumentType(method, (unsigned int)i + 2);
        valid = type && strcmp(type, args[i].UTF8String) == 0;
        free(type);
    }
    return valid;
}

static id WFRecordObject(id object, NSString *getter) {
    SEL sel = NSSelectorFromString(getter);
    if (!object || !WFRecordABI(class_getInstanceMethod(object_getClass(object), sel), "@", @[])) return nil;
    return ((id (*)(id, SEL))[object methodForSelector:sel])(object, sel);
}

static BOOL WFIsMessagesRecord(id object) {
    id bundleID = WFRecordObject(object, @"bundleIdentifier");
    return [bundleID isKindOfClass:[NSString class]] && [bundleID isEqualToString:@"com.apple.MobileSMS"];
}

static NSString *WFRecordAssociation(id value) {
    if (!value) return @"nil";
    if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
        return [NSString stringWithFormat:@"collection(count=%lu,MobileSMS=%@)",
                (unsigned long)[value count], [value containsObject:@"com.apple.MobileSMS"] ? @"YES" : @"NO"];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [value isEqualToString:@"com.apple.MobileSMS"] ? @"MobileSMS" : @"<other-string>";
    }
    return @"<unexpected-type>";
}

static void WFLogMessagesRecord(id record, NSString *stage) {
    if (!WFIsMessagesRecord(record)) return;
    Log(@"[CompanionRecord] %@ MobileSMS class=%@ counterparts=%@", stage,
        NSStringFromClass(object_getClass(record)),
        WFRecordAssociation(WFRecordObject(record, @"counterpartIdentifiers")));
}

static IMP WFOriginalLSCounterparts;
static IMP WFOriginalWatcherRecord;
static IMP WFOriginalWatcherResync;
static IMP WFOriginalSerialize;
static IMP WFOriginalRemoteSerialize;

static void WFInspectMessagesLSRecord(void) {
    Class cls = objc_lookUpClass("LSApplicationRecord");
    SEL initializer = sel_registerName("initWithBundleIdentifier:allowPlaceholder:error:");
    Method method = class_getInstanceMethod(cls, initializer);
    if (!WFRecordABI(method, "@", @[@"@", @"B", @"^@"])) {
        Log(@"[CompanionRecord] LS single-record lookup skipped ABI=%s",
            method ? method_getTypeEncoding(method) : "<missing>");
        return;
    }
    @try {
        NSError *error = nil;
        id application = [[cls alloc] initWithBundleIdentifier:@"com.apple.MobileSMS"
                                            allowPlaceholder:NO error:&error];
        Log(@"[CompanionRecord] LS single-record lookup MobileSMS present=%@ errorDomain=%@ code=%ld",
            application ? @"YES" : @"NO", error.domain ?: @"none", (long)error.code);
        if (application) {
            WFLogMessagesRecord(application, @"LS-single-record");
        }
    } @catch (NSException *exception) {
        // A failed diagnostic must not terminate appconduitd.
        Log(@"[CompanionRecord] LS read-only diagnostic failed exception=%@", exception.name);
    }
}

static id WFLSCounterparts(id self, SEL sel) {
    id result = ((id (*)(id, SEL))WFOriginalLSCounterparts)(self, sel);
    if (WFIsMessagesRecord(self)) {
        Log(@"[CompanionRecord] LS MobileSMS counterpartIdentifiers=%@", WFRecordAssociation(result));
    }
    return result;
}

static id WFWatcherRecord(id self, SEL sel, id record, id *error) {
    id result = ((id (*)(id, SEL, id, id *))WFOriginalWatcherRecord)(self, sel, record, error);
    if (WFIsMessagesRecord(record)) {
        Log(@"[CompanionRecord] watcher record lookup MobileSMS returned=%@", result ? @"YES" : @"NO");
        WFLogMessagesRecord(result, @"watcher-result");
    }
    return result;
}

static void WFWatcherResync(id self, SEL sel) {
    ((void (*)(id, SEL))WFOriginalWatcherResync)(self, sel);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ WFInspectMessagesLSRecord(); });
    // Already on the watcher's state queue: inspect only this one cached
    // record, never dispatch_sync back onto that queue or enumerate all apps.
    Ivar ivar = class_getInstanceVariable(object_getClass(self), "_appList");
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    id list = type && type[0] == '@' ? object_getIvar(self, ivar) : nil;
    if (![list isKindOfClass:[NSDictionary class]]) {
        Log(@"[CompanionRecord] watcher cache unavailable for read-only inspection");
        return;
    }
    id record = list[@"com.apple.MobileSMS"];
    if ([record isKindOfClass:[NSDictionary class]]) {
        Log(@"[CompanionRecord] watcher cache MobileSMS present=YES C=%@", WFRecordAssociation(record[@"C"]));
    } else {
        Log(@"[CompanionRecord] watcher cache MobileSMS present=%@ class=%@", record ? @"YES" : @"NO",
            record ? NSStringFromClass(object_getClass(record)) : @"nil");
        // This cache holds ACXLaunchServicesWatcherSequenceRecord, which has
        // no bundleIdentifier. The dictionary key above already identifies
        // MobileSMS; do not reject it via WFIsMessagesRecord.
        if (record) {
            SEL getter = sel_registerName("counterpartIdentifiers");
            Method method = class_getInstanceMethod(object_getClass(record), getter);
            if (WFRecordABI(method, "@", @[])) {
                Log(@"[CompanionRecord] watcher-cache MobileSMS counterparts=%@",
                    WFRecordAssociation(WFRecordObject(record, @"counterpartIdentifiers")));
            } else {
                Log(@"[CompanionRecord] watcher-cache MobileSMS counterparts getter ABI=%s",
                    method ? method_getTypeEncoding(method) : "<missing>");
            }
        }
    }
}

static void WFLogSerialization(id object, id result, NSString *stage) {
    if (!WFIsMessagesRecord(object)) return;
    WFLogMessagesRecord(object, stage);
    if ([result isKindOfClass:[NSDictionary class]]) {
        Log(@"[CompanionRecord] %@ serialized MobileSMS C=%@ counterpartIdentifiers=%@ B=%@ CFBundleIdentifier=%@",
            stage, WFRecordAssociation(result[@"C"]), WFRecordAssociation(result[@"counterpartIdentifiers"]),
            WFRecordAssociation(result[@"B"]), WFRecordAssociation(result[@"CFBundleIdentifier"]));
    } else {
        Log(@"[CompanionRecord] %@ serialized MobileSMS resultClass=%@", stage,
            result ? NSStringFromClass(object_getClass(result)) : @"nil");
    }
}

static id WFSerialize(id self, SEL sel) {
    id result = ((id (*)(id, SEL))WFOriginalSerialize)(self, sel);
    WFLogSerialization(self, result, @"serialize");
    return result;
}

static id WFRemoteSerialize(id self, SEL sel) {
    id result = ((id (*)(id, SEL))WFOriginalRemoteSerialize)(self, sel);
    WFLogSerialization(self, result, @"serializeAsRemoteApplication");
    return result;
}

static void WFObserveRecordMethod(const char *className, const char *selector, const char *result,
                                  NSArray<NSString *> *args, IMP observer, IMP *original) {
    Class cls = objc_lookUpClass(className);
    SEL sel = sel_registerName(selector);
    Method method = class_getInstanceMethod(cls, sel);
    if (!WFRecordABI(method, result, args)) {
        Log(@"[CompanionRecord] skipped %s %s ABI=%s", className, selector,
            method ? method_getTypeEncoding(method) : "<missing>");
        return;
    }
    MSHookMessageEx(cls, sel, observer, original);
    Log(@"[CompanionRecord] observing %s %s", className, selector);
}

void WFInstallCompanionRecordDiagnostics(void) {
    if (IOSMajorVersion() != 15) return;
    WFObserveRecordMethod("LSApplicationRecord", "counterpartIdentifiers", "@", @[],
        (IMP)WFLSCounterparts, &WFOriginalLSCounterparts);
    WFObserveRecordMethod("ACXLaunchServicesWatcher", "_onQueue_applicationForAppRecord:error:", "@", @[@"@", @"^@"],
        (IMP)WFWatcherRecord, &WFOriginalWatcherRecord);
    WFObserveRecordMethod("ACXLaunchServicesWatcher", "_onQueue_reSyncWithLS", "v", @[],
        (IMP)WFWatcherResync, &WFOriginalWatcherResync);
    WFObserveRecordMethod("ACXCompanionApplication", "serialize", "@", @[],
        (IMP)WFSerialize, &WFOriginalSerialize);
    WFObserveRecordMethod("ACXCompanionApplication", "serializeAsRemoteApplication", "@", @[],
        (IMP)WFRemoteSerialize, &WFOriginalRemoteSerialize);
}
