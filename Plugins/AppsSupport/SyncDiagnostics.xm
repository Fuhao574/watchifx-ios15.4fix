#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <substrate.h>
#include <string.h>
#include <stdlib.h>
#include "Logging.h"

// Observe, never suppress deletion events or alter sync messages. Only log
// dictionary keys and MobileSMS-related structure, not arbitrary payloads,
// tokens, certificates, message bodies or other installed app identifiers.
static NSString *WFSyncShape(id value, NSUInteger depth) {
    if (!value) return @"nil";
    if (depth > 4) return @"<depth-limit>";
    if ([value isKindOfClass:[NSString class]]) {
        return [value isEqualToString:@"com.apple.MobileSMS"] ? @"MobileSMS" : @"<string>";
    }
    if ([value isKindOfClass:[NSNumber class]]) return @"<number>";
    if ([value isKindOfClass:[NSData class]]) return @"<data>";
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        NSUInteger count = 0;
        for (id key in value) {
            if (count++ >= 48) { [parts addObject:@"<truncated>"]; break; }
            NSString *label = @"<key>";
            // Only protocol-looking short ASCII keys are useful here. Redact
            // all UUIDs, app identifiers and user-controlled string keys.
            if ([key isKindOfClass:[NSString class]] && [key length] <= 40 &&
                [key rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
                    @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet]].location == NSNotFound) {
                label = key;
            } else if ([key isKindOfClass:[NSNumber class]]) {
                label = [key stringValue];
            } else if ([key isEqual:@"com.apple.MobileSMS"]) {
                label = @"MobileSMS";
            }
            NSString *shape = WFSyncShape(value[key], depth + 1);
            if ([key isEqual:@"T"] && [value[key] isKindOfClass:[NSNumber class]]) {
                shape = [value[key] stringValue]; // protocol message type only
            }
            [parts addObject:[NSString stringWithFormat:@"%@:%@", label, shape]];
        }
        return [NSString stringWithFormat:@"dict(%lu){%@}", (unsigned long)[value count],
                [parts componentsJoinedByString:@","]];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        NSUInteger count = 0;
        for (id item in value) {
            if (count++ >= 48) { [parts addObject:@"<truncated>"]; break; }
            [parts addObject:WFSyncShape(item, depth + 1)];
        }
        return [NSString stringWithFormat:@"array(%lu)[%@]", (unsigned long)[value count],
                [parts componentsJoinedByString:@","]];
    }
    Class cls = object_getClass(value);
    NSString *className = NSStringFromClass(cls);
    // ACX uses message model objects, not NSDictionary, on iOS 15.4.
    // Read only object-typed stored fields of ACX models. Never invoke KVC,
    // description, or guessed getters on a private message object.
    if ([className hasPrefix:@"ACX"]) {
        NSMutableArray *parts = [NSMutableArray array];
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count && i < 48; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            NSString *name = [NSString stringWithUTF8String:ivar_getName(ivars[i])];
            NSString *shape = @"<scalar>";
            if (type && type[0] == '@') {
                shape = WFSyncShape(object_getIvar(value, ivars[i]), depth + 1);
            }
            [parts addObject:[NSString stringWithFormat:@"%@:%@", name, shape]];
        }
        free(ivars);
        return [NSString stringWithFormat:@"%@{%@}", className, [parts componentsJoinedByString:@","]];
    }
    return [NSString stringWithFormat:@"<%@>", className];
}

static IMP WFOriginalReunion;
static IMP WFOriginalDelete;
static IMP WFOriginalSend;
static IMP WFOriginalIDSSend;
static void WFLogSyncMethods(void);
static void WFProbeMobileSMSAvailability(id manager);

static void WFReunion(id self, SEL selector, id message, id manager) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ WFLogSyncMethods(); });
    Log(@"[SyncTrace] reunion IN %@", WFSyncShape(message, 0));
    WFProbeMobileSMSAvailability(manager);
    ((void (*)(id, SEL, id, id))WFOriginalReunion)(self, selector, message, manager);
    Log(@"[SyncTrace] reunion OUT");
}

// Observe the final IDS dictionary as well as the ACX wrapper. Replies may
// bypass ACXIDSMessaging's sendMessage method. Original parameters, identifier
// and error pointers are forwarded unchanged. Never log destinations/options.
static BOOL WFIDSSend(id self, SEL selector, id message, id destinations,
                     NSInteger priority, id options, id *identifier, id *error) {
    if ([message isKindOfClass:[NSDictionary class]] && message[@"T"] &&
        (message[@"DBU"] || message[@"BL"] || message[@"IA"])) {
        Log(@"[SyncTrace] IDS outbound %@", WFSyncShape(message, 0));
    }
    return ((BOOL (*)(id, SEL, id, id, NSInteger, id, id *, id *))WFOriginalIDSSend)
        (self, selector, message, destinations, priority, options, identifier, error);
}

static BOOL WFMethodMatches(Method method, const char *result, NSArray<NSString *> *args) {
    if (!method || method_getNumberOfArguments(method) != args.count + 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL safe = type && strcmp(type, result) == 0;
    free(type);
    for (NSUInteger i = 0; safe && i < args.count; i++) {
        type = method_copyArgumentType(method, (unsigned int)i + 2);
        const char *expected = args[i].UTF8String;
        safe = type && (strcmp(expected, "@") == 0 ? type[0] == '@' : strcmp(type, expected) == 0);
        free(type);
    }
    return safe;
}

static void WFProbeMobileSMSAvailability(id manager) {
    if (!manager) return;
    Class cls = object_getClass(manager);
    // Read-only queries whose existence and encodings were confirmed by the
    // preceding on-device trace. Do not force their result or swallow errors.
    for (NSString *name in @[@"_alwaysIgnoredSystemAppBundleIDs",
                             @"bundleIDsOfLocallyAvailableSystemApps",
                             @"possibleCompanionDeletableSystemAppToWatchCounterpartsMap"]) {
        SEL sel = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(cls, sel);
        if (!WFMethodMatches(method, "@", @[])) continue;
        id result = ((id (*)(id, SEL))[manager methodForSelector:sel])(manager, sel);
        BOOL member = NO;
        if ([result isKindOfClass:[NSArray class]] || [result isKindOfClass:[NSSet class]]) {
            member = [result containsObject:@"com.apple.MobileSMS"];
        } else if ([result isKindOfClass:[NSDictionary class]]) {
            member = result[@"com.apple.MobileSMS"] != nil;
        }
        Log(@"[SyncTrace] probe %@ resultClass=%@ MobileSMS-key/member=%@", name,
            result ? NSStringFromClass(object_getClass(result)) : @"nil", member ? @"YES" : @"NO");
    }
    for (NSString *name in @[@"systemAppIsAvailableWithBundleID:error:",
                             @"companionBundleIDForLocallyAvailableSystemApp:error:",
                             @"availableSystemAppWithBundleID:error:"]) {
        SEL sel = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(cls, sel);
        NSError *error = nil;
        NSString *summary = @"<ABI mismatch>";
        if (WFMethodMatches(method, "B", @[@"@", @"^@"])) {
            BOOL result = ((BOOL (*)(id, SEL, id, NSError **))[manager methodForSelector:sel])
                (manager, sel, @"com.apple.MobileSMS", &error);
            summary = result ? @"YES" : @"NO";
        } else if (WFMethodMatches(method, "@", @[@"@", @"^@"])) {
            id result = ((id (*)(id, SEL, id, NSError **))[manager methodForSelector:sel])
                (manager, sel, @"com.apple.MobileSMS", &error);
            summary = WFSyncShape(result, 0);
        }
        Log(@"[SyncTrace] probe %@ MobileSMS result=%@ errorDomain=%@ code=%ld", name,
            summary, error.domain ?: @"none", (long)error.code);
    }
}

static void WFDelete(id self, SEL selector, id message) {
    Log(@"[SyncTrace] delete-event IN %@", WFSyncShape(message, 0));
    ((void (*)(id, SEL, id))WFOriginalDelete)(self, selector, message);
    Log(@"[SyncTrace] delete-event OUT");
}

static void WFSend(id self, SEL selector, id message, id device, NSInteger priority,
                   double timeout, id logDescription, id reply) {
    // The description identifies protocol traffic, not user message contents.
    // Use only a known label, never arbitrary descriptions from the payload.
    NSString *label = @"other";
    if ([logDescription isKindOfClass:[NSString class]]) {
        NSString *lower = [logDescription lowercaseString];
        if ([lower containsString:@"reunion"]) label = @"reunion";
        else if ([lower containsString:@"installation"]) label = @"installation";
        else if ([lower containsString:@"delete"]) label = @"delete";
        else if ([lower containsString:@"ack"]) label = @"ack";
    }
    Log(@"[SyncTrace] send %@ %@", label, WFSyncShape(message, 0));
    ((void (*)(id, SEL, id, id, NSInteger, double, id, id))WFOriginalSend)
        (self, selector, message, device, priority, timeout, logDescription, reply);
}

static BOOL WFIsVoidObjectMethod(Method method, unsigned int objectArguments) {
    if (!method || method_getNumberOfArguments(method) != objectArguments + 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = type && strcmp(type, "v") == 0;
    free(type);
    for (unsigned int i = 2; valid && i < objectArguments + 2; i++) {
        type = method_copyArgumentType(method, i);
        valid = type && type[0] == '@';
        free(type);
    }
    return valid;
}

void WFInstallAppConduitDiagnostics(void) {
    // Runtime encodings, not guessed private declarations, gate each hook.
    Class cls = objc_lookUpClass("ACXCompanionSyncConnection");
    SEL reunion = sel_registerName("_onQueue_processReunionSyncMessage:withAppManager:");
    SEL deletion = sel_registerName("_onQueue_handleAppDeleteMessage:");
    if (WFIsVoidObjectMethod(class_getInstanceMethod(cls, reunion), 2)) {
        MSHookMessageEx(cls, reunion, (IMP)WFReunion, &WFOriginalReunion);
        Log(@"[SyncTrace] reunion observer installed");
    } else {
        Log(@"[SyncTrace] reunion observer skipped: missing method or different ABI");
    }
    if (WFIsVoidObjectMethod(class_getInstanceMethod(cls, deletion), 1)) {
        MSHookMessageEx(cls, deletion, (IMP)WFDelete, &WFOriginalDelete);
        Log(@"[SyncTrace] delete observer installed");
    } else {
        Log(@"[SyncTrace] delete observer skipped: missing method or different ABI");
    }
    Class messaging = objc_lookUpClass("ACXIDSMessaging");
    SEL send = sel_registerName("sendMessage:toDevice:withPriority:timeout:logDescription:handleReply:");
    Method method = class_getInstanceMethod(messaging, send);
    BOOL safe = method && method_getNumberOfArguments(method) == 8;
    if (safe) {
        char *type = method_copyReturnType(method);
        safe = type && strcmp(type, "v") == 0;
        free(type);
        const char *arguments[] = {"@", "@", "q", "d", "@", "@"};
        for (unsigned int i = 0; safe && i < 6; i++) {
            type = method_copyArgumentType(method, i + 2);
            safe = type && type[0] == arguments[i][0];
            free(type);
        }
    }
    if (safe) {
        MSHookMessageEx(messaging, send, (IMP)WFSend, &WFOriginalSend);
        Log(@"[SyncTrace] send observer installed");
    } else {
        Log(@"[SyncTrace] send observer skipped: missing method or different ABI");
    }
    Class ids = objc_lookUpClass("IDSService");
    SEL idsSend = sel_registerName("sendMessage:toDestinations:priority:options:identifier:error:");
    Method idsMethod = class_getInstanceMethod(ids, idsSend);
    if (WFMethodMatches(idsMethod, "B", @[@"@", @"@", @"q", @"@", @"^@", @"^@"])) {
        MSHookMessageEx(ids, idsSend, (IMP)WFIDSSend, &WFOriginalIDSSend);
        Log(@"[SyncTrace] IDS send observer installed");
    } else {
        Log(@"[SyncTrace] IDS send observer skipped; ABI=%s",
            idsMethod ? method_getTypeEncoding(idsMethod) : "<missing>");
    }
    WFLogSyncMethods();
}

static void WFLogSyncMethods(void) {
    for (NSString *className in @[@"ACXCompanionSyncConnection", @"ACXAvailableApplicationManager",
                                   @"ACXAvailableSystemAppList", @"ACXIDSMessaging"]) {
        Class target = objc_lookUpClass(className.UTF8String);
        Log(@"[SyncTrace] class %@ present=%@", className, target ? @"YES" : @"NO");
        unsigned int count = 0;
        Method *methods = class_copyMethodList(target, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            NSString *lower = name.lowercaseString;
            if ([lower containsString:@"reunion"] || [lower containsString:@"systemapp"] ||
                [lower containsString:@"deletemessage"] || [lower containsString:@"sendmessage"] ||
                [lower containsString:@"installable"] || [lower containsString:@"reply"]) {
                Log(@"[SyncTrace] %@ %@ ABI=%s", className, name, method_getTypeEncoding(methods[i]));
            }
        }
        free(methods);
    }
}
