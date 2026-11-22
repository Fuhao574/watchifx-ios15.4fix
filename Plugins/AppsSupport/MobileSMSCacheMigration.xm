#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <substrate.h>
#include <stdlib.h>
#include <string.h>
#include "utils.h"
#include "WFExecutableIdentity.h"

@interface NSObject (WFMigrationLSInitializer)
- (instancetype)initWithBundleIdentifier:(NSString *)bundleID allowPlaceholder:(BOOL)allowPlaceholder error:(NSError **)error;
@end

// Bounded reprocessing of a real LS record through the native handler, NOT a
// real newly observed installation. See diagnostics/binary-ios154/analysis.md.
// No app/event construction, sequence assignment, cache writes or wire sends.
static IMP WFMigrationOriginalRescan;
static IMP WFMigrationOriginalNote;
static IMP WFMigrationOriginalEvent;
static char WFMigrationAttempted;
static NSString *const WFMigrationBundle = @"com.apple.MobileSMS";

static BOOL WFMigrationABI(Class cls, const char *name, const char *result, NSArray<NSString *> *args) {
    Method m = class_getInstanceMethod(cls, sel_registerName(name));
    if (!m || method_getNumberOfArguments(m) != args.count + 2) return NO;
    char *type = method_copyReturnType(m);
    BOOL valid = type && strcmp(type, result) == 0;
    free(type);
    for (NSUInteger i = 0; valid && i < args.count; i++) {
        type = method_copyArgumentType(m, (unsigned int)i + 2);
        valid = type && strcmp(type, args[i].UTF8String) == 0;
        free(type);
    }
    return valid;
}

static id WFMigrationObject(id object, const char *name) {
    if (!object || !WFMigrationABI(object_getClass(object), name, "@", @[])) return nil;
    SEL sel = sel_registerName(name);
    return ((id (*)(id, SEL))[object methodForSelector:sel])(object, sel);
}

static unsigned long long WFMigrationNumber(id object, const char *name) {
    SEL sel = sel_registerName(name); // callers validate Q getter first
    return ((unsigned long long (*)(id, SEL))[object methodForSelector:sel])(object, sel);
}

static BOOL WFMigrationBool(id object, const char *name) {
    if (!WFMigrationABI(object_getClass(object), name, "B", @[])) return NO;
    SEL sel = sel_registerName(name);
    return ((BOOL (*)(id, SEL))[object methodForSelector:sel])(object, sel);
}

static BOOL WFMigrationEmpty(id value) {
    return !value || ([value isKindOfClass:[NSArray class]] && [value count] == 0);
}

static BOOL WFMigrationContainsSMS(id apps) {
    if (![apps isKindOfClass:[NSArray class]]) return NO;
    for (id app in apps) {
        if ([WFMigrationObject(app, "bundleIdentifier") isEqual:WFMigrationBundle]) return YES;
    }
    return NO;
}

static void WFMigrationNote(id self, SEL sel, id added, id updated, id removed, id uuid,
                            unsigned long long sequence) {
    if (WFMigrationContainsSMS(added) || WFMigrationContainsSMS(updated)) {
        Log(@"[SMSMigration] native observer MobileSMS added=%@ updated=%@ endingSequence=%llu",
            WFMigrationContainsSMS(added) ? @"YES" : @"NO",
            WFMigrationContainsSMS(updated) ? @"YES" : @"NO", sequence);
    }
    ((void (*)(id, SEL, id, id, id, id, unsigned long long))WFMigrationOriginalNote)
        (self, sel, added, updated, removed, uuid, sequence);
}

static void WFMigrationEvent(id self, SEL sel, id event) {
    if ([WFMigrationObject(event, "bundleID") isEqual:WFMigrationBundle] &&
        WFMigrationABI(object_getClass(event), "eventType", "Q", @[]) &&
        WFMigrationABI(object_getClass(event), "sequenceNumber", "Q", @[])) {
        Log(@"[SMSMigration] native event MobileSMS type=%llu sequence=%llu",
            WFMigrationNumber(event, "eventType"), WFMigrationNumber(event, "sequenceNumber"));
    }
    ((void (*)(id, SEL, id))WFMigrationOriginalEvent)(self, sel, event);
}

static BOOL WFMigrationExactExecutable(void) {
    // Never assume dyld image 0 is the host executable in an injected process.
    // Locate the defining image of the native class, NOT its hooked method IMP
    // (which now points into a tweak). Still require MH_EXECUTE and exact UUID.
    const char *owner = class_getImageName(objc_lookUpClass("ACXLaunchServicesWatcher"));
    const struct mach_header *first = _dyld_get_image_header(0);
    Log(@"[SMSMigration] identity image0 magic=0x%x filetype=%u nativeClassImage=%s",
        first ? first->magic : 0, first ? first->filetype : 0, owner ?: "<missing>");
    if (!owner || ![[NSString stringWithUTF8String:owner].lastPathComponent isEqualToString:@"appconduitd"]) return NO;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || strcmp(name, owner)) continue;
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64 || header->sizeofcmds > 1024 * 1024) return NO;
        uint8_t uuid[16] = {0};
        BOOL parsed = WFReadExecutableUUID(header, sizeof(*header) + header->sizeofcmds, uuid);
        BOOL match = parsed && memcmp(uuid, WFAnalyzedAppConduitUUID, sizeof(uuid)) == 0;
        NSString *observed = parsed ? [[NSUUID alloc] initWithUUIDBytes:uuid].UUIDString : @"<unreadable>";
        Log(@"[SMSMigration] identity native image=%u filetype=%u UUID=%@ exact=%@",
            i, header->filetype, observed, match ? @"YES" : @"NO");
        return match;
    }
    Log(@"[SMSMigration] native class image not found in dyld list; fail closed");
    return NO;
}

static void WFMigrationAfterRescan(id watcher) {
    if (objc_getAssociatedObject(watcher, &WFMigrationAttempted)) return;
    id list = WFMigrationObject(watcher, "appList");
    if (![list isKindOfClass:[NSDictionary class]]) {
        Log(@"[SMSMigration] skipped: native appList is unavailable");
        return;
    }
    id cached = list[WFMigrationBundle];
    Class sequenceClass = objc_lookUpClass("ACXLaunchServicesWatcherSequenceRecord");
    if (!sequenceClass || object_getClass(cached) != sequenceClass) {
        Log(@"[SMSMigration] skipped: expected existing MobileSMS sequence record unavailable");
        return;
    }
    if (!WFMigrationEmpty(WFMigrationObject(cached, "counterpartIdentifiers"))) {
        Log(@"[SMSMigration] skipped: existing MobileSMS association is nonempty");
        return;
    }

    Class cls = objc_lookUpClass("LSApplicationRecord");
    NSError *error = nil;
    // Object initialized by its real initializer; never create a replacement
    // model with invented fields. ARC recognizes the init method family.
    id record = [[cls alloc] initWithBundleIdentifier:WFMigrationBundle allowPlaceholder:NO error:&error];
    if (!record || error || ![record isKindOfClass:cls] ||
        ![WFMigrationObject(record, "bundleIdentifier") isEqual:WFMigrationBundle]) {
        Log(@"[SMSMigration] skipped: real MobileSMS lookup failed domain=%@ code=%ld",
            error.domain ?: @"none", (long)error.code);
        return;
    }
    if (!WFMigrationABI(object_getClass(record), "isPlaceholder", "B", @[]) ||
        WFMigrationBool(record, "isPlaceholder") ||
        !WFMigrationBool(record, "shouldBeTrackedByLaunchServicesWatcher") ||
        !WFMigrationBool(WFMigrationObject(record, "applicationState"), "isInstalled")) {
        Log(@"[SMSMigration] skipped: real MobileSMS record is not installed/tracked or is placeholder");
        return;
    }
    id cacheGUID = WFMigrationObject(record, "cacheGUID");
    id lastGUID = WFMigrationObject(watcher, "lastLSUUID");
    id dbUUID = WFMigrationObject(watcher, "ourDBUUID");
    if (![cacheGUID isKindOfClass:[NSUUID class]] || ![cacheGUID isEqual:lastGUID] ||
        ![dbUUID isKindOfClass:[NSUUID class]] ||
        !WFMigrationABI(object_getClass(record), "sequenceNumber", "Q", @[])) {
        Log(@"[SMSMigration] skipped: LS GUID/database UUID/sequence ABI validation failed GUIDClass=%@",
            cacheGUID ? NSStringFromClass(object_getClass(cacheGUID)) : @"nil");
        return;
    }
    unsigned long long ls = WFMigrationNumber(record, "sequenceNumber");
    unsigned long long cachedLS = WFMigrationNumber(cached, "lsSequenceNumber");
    unsigned long long cachedACX = WFMigrationNumber(cached, "acxSequenceNumber");
    if (ls != cachedLS) {
        Log(@"[SMSMigration] skipped: LS sequence changed (%llu vs %llu)", ls, cachedLS);
        return; // do not interfere with a genuine LS change
    }
    id counterparts = WFMigrationObject(record, "counterpartIdentifiers");
    if (![counterparts isKindOfClass:[NSArray class]] ||
        ![counterparts isEqual:@[WFMigrationBundle]]) {
        Log(@"[SMSMigration] skipped: source association is not exactly [MobileSMS]");
        return;
    }
    dispatch_queue_t queue = WFMigrationObject(watcher, "stateQueue");
    if (!queue) {
        Log(@"[SMSMigration] skipped: state queue unavailable");
        return;
    }

    objc_setAssociatedObject(watcher, &WFMigrationAttempted, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    unsigned long long before = WFMigrationNumber(watcher, "lastSequenceNumber");
    Log(@"[SMSMigration] reprocessing ONE real existing MobileSMS record via native handler LS=%llu cachedACX=%llu last=%llu",
        ls, cachedACX, before);
    SEL handler = sel_registerName("applicationsInstalledWithAppRecords:");
    ((void (*)(id, SEL, id))[watcher methodForSelector:handler])(watcher, handler, @[record]);
    // Exact binary's handler uses dispatch_async to this same state queue.
    // This check is queued behind it, not a timing-based sleep or retry loop.
    dispatch_async(queue, ^{
        @try {
            id currentList = WFMigrationObject(watcher, "appList");
            id current = [currentList isKindOfClass:[NSDictionary class]] ? currentList[WFMigrationBundle] : nil;
            if (object_getClass(current) != sequenceClass) {
                Log(@"[SMSMigration] verification failed: native cache record unavailable; no retry");
                return;
            }
            id c = WFMigrationObject(current, "counterpartIdentifiers");
            unsigned long long afterLS = WFMigrationNumber(current, "lsSequenceNumber");
            unsigned long long afterACX = WFMigrationNumber(current, "acxSequenceNumber");
            unsigned long long after = WFMigrationNumber(watcher, "lastSequenceNumber");
            BOOL association = [c isKindOfClass:[NSArray class]] && [c isEqual:@[WFMigrationBundle]];
            BOOL sameDB = [dbUUID isEqual:WFMigrationObject(watcher, "ourDBUUID")];
            Log(@"[SMSMigration] native-result association=%@ LS=%llu->%llu ACX=%llu->%llu last=%llu->%llu sameDB=%@",
                association ? @"YES" : @"NO", ls, afterLS, cachedACX, afterACX,
                before, after, sameDB ? @"YES" : @"NO");
            // Native disk encoding check only; do not write the dictionary.
            id encoded = WFMigrationObject(current, "dictionaryRepresentation");
            id cKey = [encoded isKindOfClass:[NSDictionary class]] ? encoded[@"C"] : nil;
            Log(@"[SMSMigration] native cache serialization MobileSMS C=%@ (not a retention verdict)",
                [cKey isKindOfClass:[NSArray class]] && [cKey isEqual:@[WFMigrationBundle]] ? @"YES" : @"NO");
        } @catch (NSException *exception) {
            Log(@"[SMSMigration] verification exception=%@; no retry", exception.name);
        }
    });
}

static void WFMigrationRescan(id self, SEL sel) {
    ((void (*)(id, SEL))WFMigrationOriginalRescan)(self, sel);
    @try {
        WFMigrationAfterRescan(self);
    } @catch (NSException *exception) {
        objc_setAssociatedObject(self, &WFMigrationAttempted, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        Log(@"[SMSMigration] guard/reprocessing exception=%@; no retry", exception.name);
    }
}

void WFInstallMobileSMSCacheMigration(void) {
    int major = IOSMajorVersion(), minor = IOSMinorVersion();
    if (!getprogname() || strcmp(getprogname(), "appconduitd") || major != 15 || minor != 4) {
        Log(@"[SMSMigration] disabled: host=%s realOS=%d.%d", getprogname() ?: "<nil>", major, minor);
        return;
    }
    if (!WFMigrationExactExecutable()) {
        Log(@"[SMSMigration] disabled: executable identity verification failed");
        return;
    }
    Class watcher = objc_lookUpClass("ACXLaunchServicesWatcher");
    Class record = objc_lookUpClass("LSApplicationRecord");
    Class sequence = objc_lookUpClass("ACXLaunchServicesWatcherSequenceRecord");
    BOOL valid = WFMigrationABI(watcher, "_onQueue_reSyncWithLS", "v", @[]) &&
        WFMigrationABI(watcher, "applicationsInstalledWithAppRecords:", "v", @[@"@"]) &&
        WFMigrationABI(record, "initWithBundleIdentifier:allowPlaceholder:error:", "@", @[@"@", @"B", @"^@"]) &&
        WFMigrationABI(sequence, "counterpartIdentifiers", "@", @[]) &&
        WFMigrationABI(sequence, "lsSequenceNumber", "Q", @[]) &&
        WFMigrationABI(sequence, "acxSequenceNumber", "Q", @[]) &&
        WFMigrationABI(watcher, "lastSequenceNumber", "Q", @[]) &&
        WFMigrationABI(watcher, "_onQueue_addAppEvent:", "v", @[@"@"]) &&
        WFMigrationABI(watcher, "_onQueue_noteNewApps:updatedApps:removedApps:forDBUUID:endingSequenceNumber:",
            "v", @[@"@", @"@", @"@", @"@", @"Q"]);
    for (NSString *name in @[@"appList", @"stateQueue", @"lastLSUUID", @"ourDBUUID"]) {
        valid = valid && WFMigrationABI(watcher, name.UTF8String, "@", @[]);
    }
    if (!valid) {
        Log(@"[SMSMigration] disabled: native handler/cache ABI mismatch");
        return;
    }
    MSHookMessageEx(watcher, sel_registerName("_onQueue_addAppEvent:"),
        (IMP)WFMigrationEvent, &WFMigrationOriginalEvent);
    MSHookMessageEx(watcher, sel_registerName("_onQueue_noteNewApps:updatedApps:removedApps:forDBUUID:endingSequenceNumber:"),
        (IMP)WFMigrationNote, &WFMigrationOriginalNote);
    MSHookMessageEx(watcher, sel_registerName("_onQueue_reSyncWithLS"),
        (IMP)WFMigrationRescan, &WFMigrationOriginalRescan);
    Log(@"[SMSMigration] exact-iOS15.4 bounded native reprocessing installed");
}
