#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdatomic.h>
#import <dispatch/dispatch.h>
#ifndef WF_FOCUS_PROBE_HOST_TEST
#include <substrate.h>
#endif
#include <syslog.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif
#include "utils.h"
#include "PluginConfig.h"
#include "FocusWireConverter.h"

static IMP WFFocusOriginalSend;
static IMP WFFocusOriginalIncoming;
static IMP WFFocusOriginalAck;
static atomic_uint WFFocusEventCount;
// Process-wide, not per-engine: peer/engine changes and config toggles cannot
// replenish the budget. Never reset on ACK, failure, expiry or exception.
// This is not a durable experiment token across daemon restarts.
static atomic_bool WFFocusPolicySendClaimed;

static BOOL WFFocusClaimPolicySend(void) {
    return !atomic_exchange_explicit(&WFFocusPolicySendClaimed, true, memory_order_relaxed);
}
static NSString *const kWFFocusHooksEnabledKey = @"FocusConfigCompatibilityHooksEnabled";
static char kWFFocusTransactionAssociationKey;
static char kWFFocusRouteAssociationKey;
static char kWFFocusQueueSpecificKey;
static char kWFFocusAdaptedAckRouteKey;
static BOOL WFFocusFullContractsValid;

// This independent research branch is observe-only by default at compile time.
// A stale enabled preference cannot activate behavior in a preflight build.
#ifndef WF_FOCUS_READONLY_BUILD
#define WF_FOCUS_READONLY_BUILD 1
#endif

static const uint8_t kWFFocusFrameworkUUID[16] = {
    0x3c, 0x26, 0x01, 0x42, 0x82, 0x3b, 0x32, 0x28,
    0xb7, 0x2b, 0x9b, 0xc0, 0x74, 0x33, 0x4e, 0x29,
};
static const uint8_t kWFFocusDaemonUUID[16] = {
    0xd2, 0xc8, 0xdf, 0xb7, 0x77, 0xd4, 0x32, 0xea,
    0x8e, 0x15, 0x40, 0x60, 0x38, 0x7c, 0x71, 0x05,
};

@interface NSObject (WFFocusNativeObjects)
- (id)delegate;
- (NSUInteger)syncServiceType;
- (NSString *)deviceIdentifier;
- (id)metadata;
- (instancetype)initWithDestination:(NSUInteger)destination
                      partitionType:(NSUInteger)partitionType
               redactSensitiveData:(BOOL)redactSensitiveData
                   contactProvider:(id)contactProvider
        applicationIdentifierMapper:(id)applicationIdentifierMapper;
+ (instancetype)newWithDictionaryRepresentation:(NSDictionary *)representation context:(id)context;
- (void)_queue_removeAllInflightMetadata;
- (BOOL)_queue_cancelInflightExpirationTimer;
- (void)setSyncDate:(id)date forRecordsMatchingMetadata:(id)metadata forPairedDeviceIdentifier:(id)identifier;
@end

@class WFFocusRouteSnapshot;
@interface WFFocusTransaction : NSObject
@property(nonatomic, weak) id service;
@property(nonatomic, weak) id engine;
@property(nonatomic, strong) NSDictionary *message;
@property(nonatomic, strong) id destinations;
@property(nonatomic, copy) NSString *pairedDeviceIdentifier;
@property(nonatomic, strong) id expectedMetadata;
@property(nonatomic, assign) NSTimeInterval expiresAtUptime;
@property(nonatomic, assign) BOOL transportSucceeded;
@property(nonatomic, strong) WFFocusRouteSnapshot *route;
@end
@implementation WFFocusTransaction
@end

// Published atomically on the service; never contains mutable transaction state.
@interface WFFocusRouteSnapshot : NSObject
@property(nonatomic, readonly, weak) id engine;
@property(nonatomic, readonly, strong) dispatch_queue_t ownerQueue;
@property(nonatomic, readonly, copy) NSString *peer;
@property(nonatomic, readonly) NSTimeInterval deadline;
- (instancetype)initWithEngine:(id)engine queue:(dispatch_queue_t)queue
                         peer:(NSString *)peer deadline:(NSTimeInterval)deadline;
@end
@implementation WFFocusRouteSnapshot
- (instancetype)initWithEngine:(id)engine queue:(dispatch_queue_t)queue
                         peer:(NSString *)peer deadline:(NSTimeInterval)deadline {
    if ((self = [super init])) { _engine = engine; _ownerQueue = queue; _peer = [peer copy]; _deadline = deadline; }
    return self;
}
@end

static dispatch_queue_t WFFocusEngineQueue(id engine) {
    if (!engine || object_getClass(engine) != objc_lookUpClass("DNDSIDSSyncEngine")) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(engine), "_queue");
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!type || strcmp(type, "@\"NSObject<OS_dispatch_queue>\"") != 0) return nil;
    // Exact native immutable-after-init queue ivar. No guessed pointer offsets.
    id value = object_getIvar(engine, ivar);
    if (!value) return nil;
    dispatch_queue_t queue = (dispatch_queue_t)value;
    dispatch_queue_set_specific(queue, &kWFFocusQueueSpecificKey, (__bridge void *)queue, NULL);
    return queue;
}

static BOOL WFFocusOnEngineQueue(id engine) {
    dispatch_queue_t queue = WFFocusEngineQueue(engine);
    return queue && dispatch_get_specific(&kWFFocusQueueSpecificKey) == (__bridge void *)queue;
}

static NSString *WFFocusLocalPeerOnOwner(id engine, id service) {
    if (!service || !WFFocusOnEngineQueue(engine)) return nil;
    Class pairedClass = objc_lookUpClass("DNDSPairedDevice");
    if (!pairedClass || CopyObjectIvarValueByName(engine, "_syncService", Nil) != service) return nil;
    id paired = CopyObjectIvarValueByName(engine, "_pairedDevice", pairedClass);
    if (!paired || object_getClass(paired) != pairedClass || [paired syncServiceType] != 1) return nil;
    NSString *peer = [paired deviceIdentifier];
    return [peer isKindOfClass:[NSString class]] && peer.length ? peer : nil;
}

static BOOL WFFocusHooksEnabled(void) {
#if WF_FOCUS_READONLY_BUILD
    return NO;
#elif defined(WF_FOCUS_PROBE_HOST_TEST)
    extern BOOL WFFocusTestHooksEnabled;
    return WFFocusTestHooksEnabled;
#else
    return WFCurrentPluginBooleanConfigurationValue(kWFFocusHooksEnabledKey, NO);
#endif
}

static NSTimeInterval WFFocusUptime(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

static BOOL WFFocusConsumeExperimentPermit(void) {
#if defined(WF_FOCUS_PROBE_HOST_TEST) && !WF_FOCUS_READONLY_BUILD
    extern BOOL WFFocusTestPermitAllowed;
    return WFFocusTestPermitAllowed; // Host mock only; never a device grant.
#else
    // No device issuer/process binding has been audited or implemented yet.
    // A preference and the in-memory quota alone must NEVER authorize sending.
    return NO;
#endif
}

static BOOL WFFocusABI(Method method, const char *result, NSArray<NSString *> *arguments) {
    if (!method || method_getNumberOfArguments(method) != arguments.count + 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = type && strcmp(type, result) == 0;
    free(type);
    for (NSUInteger index = 0; valid && index < arguments.count; index++) {
        type = method_copyArgumentType(method, (unsigned int)index + 2);
        valid = type && strcmp(type, arguments[index].UTF8String) == 0;
        free(type);
    }
    return valid;
}

static int WFFocusReadUUID(const void *bytes, size_t available, uint8_t uuid[16]) {
    if (!bytes || available < sizeof(struct mach_header_64)) return 0;
    const struct mach_header_64 *header = (const struct mach_header_64 *)bytes;
    if (header->magic != MH_MAGIC_64 || header->sizeofcmds > available - sizeof(*header)) return 0;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    size_t remaining = header->sizeofcmds;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if (remaining < sizeof(struct load_command)) return 0;
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > remaining) return 0;
        if (command->cmd == LC_UUID) {
            if (command->cmdsize < sizeof(struct uuid_command)) return 0;
            memcpy(uuid, ((const struct uuid_command *)command)->uuid, 16);
            return 1;
        }
        cursor += command->cmdsize;
        remaining -= command->cmdsize;
    }
    return 0;
}

static BOOL WFFocusImageMatches(const char *owner, const uint8_t expected[16], NSString *label) {
    if (!owner) return NO;
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);
        if (!name || strcmp(name, owner) != 0) continue;
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(index);
        if (!header || header->magic != MH_MAGIC_64 || header->sizeofcmds > 1024 * 1024) return NO;
        uint8_t uuid[16] = {0};
        BOOL parsed = WFFocusReadUUID(header, sizeof(*header) + header->sizeofcmds, uuid);
        BOOL matches = parsed && memcmp(uuid, expected, 16) == 0;
        NSString *observed = parsed ? [[NSUUID alloc] initWithUUIDBytes:uuid].UUIDString : @"<unreadable>";
        Log(@"[FocusCompatProbe] %@ image=%@ filetype=%u UUID=%@ exact=%@",
            label, [NSString stringWithUTF8String:name].lastPathComponent,
            header->filetype, observed, matches ? @"YES" : @"NO");
        return matches;
    }
    Log(@"[FocusCompatProbe] %@ image not found; fail closed", label);
    return NO;
}

static BOOL WFFocusMethodOwnedByImage(Method method, const char *owner) {
    if (!method || !owner) return NO;
    void *implementation = (void *)method_getImplementation(method);
    if (!implementation) return NO;
#if __has_feature(ptrauth_calls)
    implementation = ptrauth_strip(implementation, ptrauth_key_function_pointer);
#endif
    Dl_info info = {};
    return dladdr(implementation, &info) != 0 && info.dli_fname && strcmp(info.dli_fname, owner) == 0;
}

static NSString *WFFocusAction(id value) {
    if (![value isKindOfClass:[NSString class]]) return @"missing";
    for (NSString *known in @[@"update", @"replace", @"ack", @"resync", @"unlock"]) {
        if ([value isEqualToString:known]) return known;
    }
    return @"unknown";
}

static NSUInteger WFFocusCount(id value) {
    return [value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]] ? [value count] : 0;
}

static NSString *WFFocusDictionaryShape(id dictionary) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return @"<not-dict>";
    NSMutableArray *parts = [NSMutableArray arrayWithCapacity:[dictionary count]];
    // Classify before sorting: heterogeneous keys may not implement compare:.
    for (id key in dictionary) {
        if (![key isKindOfClass:[NSString class]]) {
            [parts addObject:@"<non-string-key>"];
            continue;
        }
        id value = dictionary[key];
        NSString *type = @"other";
        if ([value isKindOfClass:[NSString class]]) type = @"string";
        else if ([value isKindOfClass:[NSNumber class]]) type = @"number";
        else if ([value isKindOfClass:[NSData class]]) type = @"data";
        else if ([value isKindOfClass:[NSArray class]]) type = @"array";
        else if ([value isKindOfClass:[NSDictionary class]]) type = @"dict";
        else if ([value isKindOfClass:[NSNull class]]) type = @"null";
        [parts addObject:[NSString stringWithFormat:@"%@:%@", key, type]];
    }
    [parts sortUsingSelector:@selector(compare:)];
    return [parts componentsJoinedByString:@","];
}

static NSString *WFFocusEnvelopeShape(id message) {
    if (![message isKindOfClass:[NSDictionary class]]) return @"<not-dict>";
    return [NSString stringWithFormat:@"h={%@} d={%@}",
        WFFocusDictionaryShape(message[@"h"]), WFFocusDictionaryShape(message[@"d"])];
}

static unsigned int WFFocusNextEvent(void) {
    return atomic_fetch_add_explicit(&WFFocusEventCount, 1, memory_order_relaxed) + 1;
}

static id WFFocusLocalEngine(id service, id destinations, NSString **pairedIdentifier) {
    id engine = [service delegate];
    Class engineClass = objc_lookUpClass("DNDSIDSSyncEngine");
    Class pairedClass = objc_lookUpClass("DNDSPairedDevice");
    if (!engineClass || !pairedClass || object_getClass(engine) != engineClass) return nil;
    NSString *identifier = WFFocusLocalPeerOnOwner(engine, service);
    if (![identifier isKindOfClass:[NSString class]] || ![destinations isKindOfClass:[NSSet class]] ||
        [destinations count] != 1 || ![[destinations anyObject] isEqual:identifier]) return nil;
    if (pairedIdentifier) *pairedIdentifier = identifier;
    return engine;
}

static void WFFocusCleanupNativeInflight(id engine) {
    if (!WFFocusOnEngineQueue(engine)) return;
    [engine _queue_removeAllInflightMetadata];
    [engine _queue_cancelInflightExpirationTimer];
}

static BOOL WFFocusCleanupNativeInflightIfSafe(id engine) {
    Class cls = object_getClass(engine);
    if (!WFFocusABI(class_getInstanceMethod(cls, sel_registerName("_queue_removeAllInflightMetadata")), "v", @[]) ||
        !WFFocusABI(class_getInstanceMethod(cls, sel_registerName("_queue_cancelInflightExpirationTimer")), "B", @[])) {
        return NO;
    }
    WFFocusCleanupNativeInflight(engine);
    return YES;
}

static void WFFocusClearTransaction(id engine, WFFocusTransaction *transaction);

static WFFocusTransaction *WFFocusCurrentTransaction(id engine) {
    if (!WFFocusOnEngineQueue(engine)) return nil;
    WFFocusTransaction *transaction = objc_getAssociatedObject(engine, &kWFFocusTransactionAssociationKey);
    if (transaction && transaction.expiresAtUptime <= WFFocusUptime()) {
        WFFocusClearTransaction(engine, transaction);
        Log(@"[FocusCompat] custom transaction expired; no ACK or completion was fabricated");
        return nil;
    }
    return transaction;
}

static void WFFocusClearTransaction(id engine, WFFocusTransaction *transaction) {
    if (!WFFocusOnEngineQueue(engine)) return;
    if (objc_getAssociatedObject(engine, &kWFFocusTransactionAssociationKey) == transaction) {
        objc_setAssociatedObject(engine, &kWFFocusTransactionAssociationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id service = transaction.service;
        WFFocusRouteSnapshot *route = objc_getAssociatedObject(service, &kWFFocusRouteAssociationKey);
        if ([route isKindOfClass:[WFFocusRouteSnapshot class]] && route.engine == engine)
            objc_setAssociatedObject(service, &kWFFocusRouteAssociationKey, nil, OBJC_ASSOCIATION_RETAIN);
    }
}

static NSArray *WFFocusNativeMetadataObjects(NSArray *representations) {
    Class providerClass = objc_lookUpClass("DNDSContactProvider");
    Class mapperClass = objc_lookUpClass("DNDSApplicationIdentifierMapper");
    Class contextClass = objc_lookUpClass("DNDSBackingStoreDictionaryContext");
    Class metadataClass = objc_lookUpClass("DNDSIDSRecordMetadata");
    if (!providerClass || !mapperClass || !contextClass || !metadataClass) return nil;
    id provider = [[providerClass alloc] init];
    id mapper = [[mapperClass alloc] init];
    id context = [[contextClass alloc] initWithDestination:0
                                             partitionType:3
                                      redactSensitiveData:NO
                                          contactProvider:provider
                               applicationIdentifierMapper:mapper];
    if (!context) return nil;
    NSMutableArray *metadataObjects = [NSMutableArray arrayWithCapacity:representations.count];
    for (id representation in representations) {
        if (![representation isKindOfClass:[NSDictionary class]]) return nil;
        id metadata = [metadataClass newWithDictionaryRepresentation:representation context:context];
        if (!metadata) return nil;
        [metadataObjects addObject:metadata];
    }
    return metadataObjects;
}

static void WFFocusTransportCompletion(id engine, WFFocusTransaction *transaction,
                                       BOOL success, NSError *error) {
    if (!engine || !transaction) return;
    dispatch_queue_t queue = WFFocusEngineQueue(engine);
    if (!queue) return;
    if (!WFFocusOnEngineQueue(engine)) {
        // Never synchronously wait for engine from service: native acceptance
        // already synchronously visits engine. A second sync edge could deadlock.
        dispatch_async(queue, ^{ WFFocusTransportCompletion(engine, transaction, success, error); });
        return;
    }
    if (objc_getAssociatedObject(engine, &kWFFocusTransactionAssociationKey) != transaction) return;
    if (!WFFocusHooksEnabled() || transaction.expiresAtUptime <= WFFocusUptime()) {
        WFFocusClearTransaction(engine, transaction);
        Log(@"[FocusCompat] completion after disable/expiry discarded without ACK update");
        return;
    }
    if (!success) {
        Log(@"[FocusCompat] transport failed domain=%@ code=%ld; custom transaction cleared without ACK",
            error.domain ?: @"none", (long)error.code);
        WFFocusClearTransaction(engine, transaction);
        return;
    }
    transaction.transportSucceeded = YES;
    Log(@"[FocusCompat] transport succeeded; awaiting real update ACK, not policy confirmation");
}

static BOOL WFFocusTryConvertedSend(id service, SEL selector, id message, NSUInteger version,
                                    id messageType, id destinations, id completion) {
    if (!WFFocusHooksEnabled() || version != 10 || ![messageType isKindOfClass:[NSString class]] ||
        ![messageType isEqualToString:@"syncEngine"] ||
        ![message isKindOfClass:[NSDictionary class]]) return NO;
    NSString *action = [message[@"action"] isKindOfClass:[NSString class]] ? message[@"action"] : nil;
    BOOL policyBatch = [action isEqualToString:@"update"] || [action isEqualToString:@"replace"];
    BOOL control = [action isEqualToString:@"resync"] || [action isEqualToString:@"unlock"];
    // Do not upgrade native resync/unlock: they can reset metadata and cause
    // further sends. A policy-only experiment does not authorize that bootstrap.
    if (control || !policyBatch) return NO;

    NSString *pairedIdentifier = nil;
    id engine = WFFocusLocalEngine(service, destinations, &pairedIdentifier);
    if (!engine) return NO;
    if (!WFFocusFullContractsValid) {
        Log(@"[FocusCompat] BLOCK native %@: full runtime contracts are unavailable", action);
        WFFocusCleanupNativeInflightIfSafe(engine);
        return YES;
    }
    WFFocusTransaction *existing = WFFocusCurrentTransaction(engine);
    if (atomic_load_explicit(&WFFocusPolicySendClaimed, memory_order_relaxed)) {
        Log(@"[FocusCompat] BLOCK native %@: process policy-send budget already consumed", action);
        WFFocusCleanupNativeInflight(engine);
        return YES;
    }
    if (existing) {
        Log(@"[FocusCompat] duplicate native %@ suppressed while custom update awaits ACK", action);
        WFFocusCleanupNativeInflight(engine);
        return YES;
    }

    NSDictionary *converted = nil;
    BOOL nativeSendStarted = NO;
    @try {
        NSError *conversionError = nil;
        // User scope: one Sleep record only; unrelated modes are not sent.
        converted = WFFocusConvertSleepMessage(message, &conversionError);
        if (!converted) {
            Log(@"[FocusCompat] BLOCK native %@: conversion refused code=%ld", action, (long)conversionError.code);
            WFFocusCleanupNativeInflight(engine);
            return YES;
        }
        id record = [converted[@"modifiedRecords"] firstObject];
        id expectedMetadata = nil;
        if ([record isKindOfClass:[NSDictionary class]]) {
            id representation = record[@"metadata"];
            if ([representation isKindOfClass:[NSDictionary class]]) {
                NSArray *parsed = WFFocusNativeMetadataObjects(@[representation]);
                if (parsed.count == 1) expectedMetadata = parsed[0];
            }
        } else if ([record respondsToSelector:@selector(metadata)]) {
            expectedMetadata = [record metadata];
        }
        if (!expectedMetadata) {
            Log(@"[FocusCompat] BLOCK converted update: native record metadata is unavailable");
            WFFocusCleanupNativeInflight(engine);
            return YES;
        }

        WFFocusTransaction *transaction = [WFFocusTransaction new];
        transaction.service = service;
        transaction.engine = engine;
        transaction.message = converted;
        transaction.destinations = destinations;
        transaction.pairedDeviceIdentifier = pairedIdentifier;
        transaction.expectedMetadata = expectedMetadata;
        transaction.expiresAtUptime = WFFocusUptime() + 90.0;

        // Irreversible reservation before transaction installation and original
        // send. A synchronous throw must not make another attempt possible.
        if (!WFFocusClaimPolicySend()) {
            Log(@"[FocusCompat] BLOCK native %@: policy-send budget lost to another caller", action);
            WFFocusCleanupNativeInflight(engine);
            return YES;
        }
        if (!WFFocusConsumeExperimentPermit()) {
            Log(@"[FocusCompat] BLOCK policy send: no audited durable experiment permit");
            WFFocusCleanupNativeInflight(engine);
            return YES;
        }

        // The native v10 call has already created volatile inflight state. Take
        // ownership before sending v11; no initial-sync or database flag is changed.
        WFFocusCleanupNativeInflight(engine);
        objc_setAssociatedObject(engine, &kWFFocusTransactionAssociationKey, transaction,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        WFFocusRouteSnapshot *route = [[WFFocusRouteSnapshot alloc] initWithEngine:engine
            queue:WFFocusEngineQueue(engine) peer:pairedIdentifier deadline:transaction.expiresAtUptime];
        transaction.route = route;
        objc_setAssociatedObject(service, &kWFFocusRouteAssociationKey, route, OBJC_ASSOCIATION_RETAIN);
        __weak id weakEngine = engine;
        __weak WFFocusTransaction *weakTransaction = transaction;
        void (^customCompletion)(BOOL, id, id) = ^(BOOL success, id requestIdentifier, id error) {
            (void)requestIdentifier;
            WFFocusTransportCompletion(weakEngine, weakTransaction, success, error);
        };
        @try {
            Log(@"[FocusCompat] sending single Sleep v11 update; native action=%@", action);
            nativeSendStarted = YES;
            ((void (*)(id, SEL, id, NSUInteger, id, id, id))WFFocusOriginalSend)
                (service, selector, converted, 11, messageType, destinations, customCompletion);
        } @catch (NSException *exception) {
            WFFocusClearTransaction(engine, transaction);
            @throw;
        }
        return YES;
    } @catch (NSException *exception) {
        if (nativeSendStarted) {
            WFFocusClearTransaction(engine, objc_getAssociatedObject(engine, &kWFFocusTransactionAssociationKey));
            @throw;
        }
        Log(@"[FocusCompat] BLOCK native %@ after conversion exception=%@", action, exception.name);
        WFFocusCleanupNativeInflight(engine);
        return YES;
    }
}

static BOOL WFFocusHandleCustomAck(id engine, id message, id pairedDeviceIdentifier) {
#if WF_FOCUS_READONLY_BUILD
    return NO; // Do not even register queue-specific state in a read-only ACK.
#else
    if (!WFFocusOnEngineQueue(engine)) return NO;
    if (!WFFocusHooksEnabled()) {
#if !WF_FOCUS_READONLY_BUILD
        WFFocusTransaction *pending = WFFocusCurrentTransaction(engine);
        if (pending) WFFocusClearTransaction(engine, pending);
#endif
        return NO; // Disabled override always yields native handling.
    }
    if (!WFFocusFullContractsValid) return NO;
    id service = CopyObjectIvarValueByName(engine, "_syncService", Nil);
    NSString *activePeer = WFFocusLocalPeerOnOwner(engine, service);
    if (![pairedDeviceIdentifier isKindOfClass:[NSString class]] || ![activePeer isEqualToString:pairedDeviceIdentifier]) return NO;
    WFFocusTransaction *transaction = WFFocusCurrentTransaction(engine);
    if (!transaction || ![transaction.pairedDeviceIdentifier isEqual:pairedDeviceIdentifier]) return NO;
    @try {
        if (![message isKindOfClass:[NSDictionary class]] ||
            ![message[@"action"] isKindOfClass:[NSString class]] ||
            ![message[@"action"] isEqualToString:@"ack"] ||
            ![message[@"ackAction"] isKindOfClass:[NSString class]] ||
            ![message[@"ackAction"] isEqualToString:@"update"] ||
            ![message[@"metadataAck"] isKindOfClass:[NSArray class]] ||
            [message[@"metadataAck"] count] != 1 ||
            ![message[@"syncDate"] isKindOfClass:[NSNumber class]]) {
            Log(@"[FocusCompat] malformed or non-update ACK held for the bounded transaction");
            return YES;
        }
        NSArray *metadataObjects = WFFocusNativeMetadataObjects(message[@"metadataAck"]);
        if (metadataObjects.count != 1 || ![transaction.expectedMetadata isEqual:metadataObjects[0]]) {
            Log(@"[FocusCompat] real ACK metadata does not match the converted Sleep record");
            return YES;
        }
        Class storeClass = objc_lookUpClass("DNDSIDSSyncEngineMetadataStore");
        id store = CopyObjectIvarValueByName(engine, "_metadataStore", storeClass);
        if (!store) {
            Log(@"[FocusCompat] native metadata store unavailable; ACK not consumed");
            return YES;
        }
        NSDate *syncDate = [NSDate dateWithTimeIntervalSinceReferenceDate:[message[@"syncDate"] doubleValue]];
        [store setSyncDate:syncDate forRecordsMatchingMetadata:metadataObjects
            forPairedDeviceIdentifier:pairedDeviceIdentifier];
        WFFocusClearTransaction(engine, transaction);
        Log(@"[FocusCompat] real update ACK matched; native sync date updated, Watch policy storage still requires verification");
        return YES;
    } @catch (NSException *exception) {
        Log(@"[FocusCompat] ACK handling exception=%@; transaction remains bounded", exception.name);
        return YES;
    }
#endif
}

static void WFFocusSend(id self, SEL selector, id message, NSUInteger version,
                        id messageType, id destinations, id completion) {
    unsigned int event = WFFocusNextEvent();
    if (event <= 128) {
        NSDictionary *body = [message isKindOfClass:[NSDictionary class]] ? message : nil;
        NSString *action = WFFocusAction(body[@"action"]);
        NSString *type = [messageType isKindOfClass:[NSString class]] &&
            [messageType isEqualToString:@"syncEngine"] ? @"syncEngine" : @"other";
        Log(@"[FocusCompatProbe] outbound event=%u version=%lu type=%@ action=%@ modified=%lu deleted=%lu destinationsPresent=%@",
            event, (unsigned long)version, type, action,
            (unsigned long)WFFocusCount(body[@"modifiedRecords"]),
            (unsigned long)WFFocusCount(body[@"deletedMetadata"]), destinations ? @"YES" : @"NO");
        NSArray *records = body[@"modifiedRecords"];
        if ([records isKindOfClass:[NSArray class]]) {
            NSUInteger index = 0;
            for (id record in records) {
                if (index++ >= 4) {
                    Log(@"[FocusCompatProbe] record schema truncated after four entries");
                    break;
                }
                Log(@"[FocusCompatProbe] outbound record %lu %@",
                    (unsigned long)index, WFFocusRecordSchemaSummary(record));
            }
        }
    }
    if (WFFocusTryConvertedSend(self, selector, message, version, messageType, destinations, completion)) {
        return;
    }
    ((void (*)(id, SEL, id, NSUInteger, id, id, id))WFFocusOriginalSend)
        (self, selector, message, version, messageType, destinations, completion);
}

static void WFFocusIncoming(id self, SEL selector, id message, id deviceIdentifier) {
    unsigned int event = WFFocusNextEvent();
    if (event <= 128) {
        NSDictionary *envelope = [message isKindOfClass:[NSDictionary class]] ? message[@"h"] : nil;
        if (![envelope isKindOfClass:[NSDictionary class]]) envelope = nil;
        NSNumber *version = [envelope[@"r"] isKindOfClass:[NSNumber class]] ? envelope[@"r"] : nil;
        NSString *type = [envelope[@"y"] isKindOfClass:[NSString class]] &&
            [envelope[@"y"] isEqualToString:@"syncEngine"] ? @"syncEngine" : @"other";
        NSDictionary *body = [message isKindOfClass:[NSDictionary class]] ? message[@"d"] : nil;
        if (![body isKindOfClass:[NSDictionary class]]) body = nil;
        Log(@"[FocusCompatProbe] inbound schema=hd-offline1 event=%u version=%@ type=%@ action=%@ ackAction=%@ metadataAck=%lu peerPresent=%@ shape=%@",
            event, version ?: @"missing", type, WFFocusAction(body[@"action"]),
            WFFocusAction(body[@"ackAction"]),
            (unsigned long)WFFocusCount(body[@"metadataAck"]), deviceIdentifier ? @"YES" : @"NO",
            WFFocusEnvelopeShape(message));
    }
    NSDictionary *focusEnvelope = [message isKindOfClass:[NSDictionary class]] ? message[@"h"] : nil;
    if (WFFocusHooksEnabled() && [focusEnvelope isKindOfClass:[NSDictionary class]] &&
        [focusEnvelope[@"y"] isKindOfClass:[NSString class]] &&
        [focusEnvelope[@"y"] isEqualToString:@"syncEngine"]) {
        NSNumber *incomingVersion = [focusEnvelope[@"r"] isKindOfClass:[NSNumber class]] ? focusEnvelope[@"r"] : nil;
        // Native v10 is not part of the compatibility override. For new wire
        // versions require an immutable route published by an actual local send.
        if ([incomingVersion isEqualToNumber:@10]) {
            ((void (*)(id, SEL, id, id))WFFocusOriginalIncoming)(self, selector, message, deviceIdentifier);
            return;
        }
        if (!WFFocusFullContractsValid) {
            Log(@"[FocusCompat] BLOCK incoming v%@: full runtime contracts are unavailable", incomingVersion);
            return;
        }
        WFFocusRouteSnapshot *route = objc_getAssociatedObject(self, &kWFFocusRouteAssociationKey);
        if (![route isKindOfClass:[WFFocusRouteSnapshot class]] || !route.engine || route.engine != [self delegate] ||
            ![deviceIdentifier isKindOfClass:[NSString class]] || ![route.peer isEqualToString:deviceIdentifier] ||
            route.deadline <= WFFocusUptime()) {
            Log(@"[FocusCompat] BLOCK incoming new-wire message: no matching live local route");
            return;
        }
        NSDictionary *incomingBody = [message[@"d"] isKindOfClass:[NSDictionary class]] ? message[@"d"] : nil;
        if (![incomingBody[@"action"] isKindOfClass:[NSString class]] || ![incomingBody[@"action"] isEqualToString:@"ack"]) {
            Log(@"[FocusCompat] BLOCK incoming new-wire control/policy: ACK-only experiment boundary");
            return;
        }
        NSError *conversionError = nil;
        BOOL changed = NO;
        NSDictionary *converted = WFFocusDownconvertIncomingMessage(message, &changed, &conversionError);
        if (!converted) {
            Log(@"[FocusCompat] BLOCK incoming Focus message: conversion refused code=%ld", (long)conversionError.code);
            return;
        }
        // The unchanged native acceptance callback still checks CURRENT peer
        // on engine queue; this snapshot does not bypass that gate.
        if (changed) {
            Log(@"[FocusCompat] adapted real incoming Focus envelope to native v10");
        }
        // A fresh body records which exact transaction authorized adaptation.
        // Native delivery may queue it until after that transaction ends. Do
        // not let such a late adapted ACK fall through to the native ACK writer.
        NSMutableDictionary *taggedBody = [converted[@"d"] mutableCopy];
        if (!taggedBody || taggedBody == converted[@"d"]) {
            Log(@"[FocusCompat] BLOCK adapted ACK: distinct body copy unavailable");
            return;
        }
        objc_setAssociatedObject(taggedBody, &kWFFocusAdaptedAckRouteKey, route, OBJC_ASSOCIATION_RETAIN);
        NSMutableDictionary *taggedMessage = [converted mutableCopy];
        taggedMessage[@"d"] = taggedBody;
        message = taggedMessage;
    }
    ((void (*)(id, SEL, id, id))WFFocusOriginalIncoming)(self, selector, message, deviceIdentifier);
}

static void WFFocusAck(id self, SEL selector, id message, id pairedDeviceIdentifier) {
    unsigned int event = WFFocusNextEvent();
    if (event <= 128) {
        NSDictionary *body = [message isKindOfClass:[NSDictionary class]] ? message : nil;
        NSString *ackAction = WFFocusAction(body[@"ackAction"]);
        Log(@"[FocusCompatProbe] native ACK event=%u action=%@ metadata=%lu peerPresent=%@",
            event, ackAction, (unsigned long)WFFocusCount(body[@"metadataAck"]),
            pairedDeviceIdentifier ? @"YES" : @"NO");
    }
#if !WF_FOCUS_READONLY_BUILD
    WFFocusRouteSnapshot *adaptedRoute = objc_getAssociatedObject(message, &kWFFocusAdaptedAckRouteKey);
    if ([adaptedRoute isKindOfClass:[WFFocusRouteSnapshot class]]) {
        if (!WFFocusOnEngineQueue(self)) return;
        WFFocusTransaction *pending = WFFocusCurrentTransaction(self);
        id service = CopyObjectIvarValueByName(self, "_syncService", Nil);
        WFFocusRouteSnapshot *published = objc_getAssociatedObject(service, &kWFFocusRouteAssociationKey);
        if (WFFocusHooksEnabled() && WFFocusFullContractsValid && pending &&
            pending.route == adaptedRoute && published == adaptedRoute && adaptedRoute.engine == self &&
            [adaptedRoute.peer isEqual:pairedDeviceIdentifier] && adaptedRoute.deadline > WFFocusUptime()) {
            WFFocusHandleCustomAck(self, message, pairedDeviceIdentifier);
        } else if (pending && !WFFocusHooksEnabled()) {
#if !WF_FOCUS_READONLY_BUILD
            WFFocusClearTransaction(self, pending);
#endif
        }
        // Always consume locally adapted ACKs, including stale/duplicate ones.
        // Never authorize a native metadata update via a formerly valid route.
        return;
    }
    if (WFFocusHandleCustomAck(self, message, pairedDeviceIdentifier)) {
        return;
    }
#endif
    ((void (*)(id, SEL, id, id))WFFocusOriginalAck)(self, selector, message, pairedDeviceIdentifier);
}

static BOOL WFFocusValidateMethod(Class cls, const char *name, const char *result, NSArray *arguments) {
    SEL selector = sel_registerName(name);
    Method method = class_getInstanceMethod(cls, selector);
    BOOL abi = WFFocusABI(method, result, arguments);
    BOOL owner = abi && WFFocusMethodOwnedByImage(method, class_getImageName(cls));
    Log(@"[FocusCompatProbe] contract class=%s selector=%s ABI=%s abi=%@ nativeOwner=%@",
        class_getName(cls), name, method ? method_getTypeEncoding(method) : "<missing>",
        abi ? @"YES" : @"NO", owner ? @"YES" : @"NO");
    return abi && owner;
}

static BOOL WFFocusValidateClassMethod(Class cls, const char *name, const char *result, NSArray *arguments) {
    SEL selector = sel_registerName(name);
    Method method = class_getClassMethod(cls, selector);
    BOOL abi = WFFocusABI(method, result, arguments);
    BOOL owner = abi && WFFocusMethodOwnedByImage(method, class_getImageName(cls));
    Log(@"[FocusCompatProbe] contract classMethod=%s selector=%s ABI=%s abi=%@ nativeOwner=%@",
        class_getName(cls), name, method ? method_getTypeEncoding(method) : "<missing>",
        abi ? @"YES" : @"NO", owner ? @"YES" : @"NO");
    return abi && owner;
}

static BOOL WFFocusValidateFullContracts(Class service, Class engine) {
    Class paired = objc_lookUpClass("DNDSPairedDevice");
    Class record = objc_lookUpClass("DNDSIDSRecord");
    Class metadata = objc_lookUpClass("DNDSIDSRecordMetadata");
    Class store = objc_lookUpClass("DNDSIDSSyncEngineMetadataStore");
    Class context = objc_lookUpClass("DNDSBackingStoreDictionaryContext");
    Class provider = objc_lookUpClass("DNDSContactProvider");
    Class mapper = objc_lookUpClass("DNDSApplicationIdentifierMapper");
    if (!paired || !record || !metadata || !store || !context || !provider || !mapper) return NO;
    for (Class cls in @[paired, record, metadata, store, context, provider, mapper]) {
        if (!WFFocusImageMatches(class_getImageName(cls), kWFFocusFrameworkUUID, @"full-contract")) return NO;
    }

    BOOL valid = YES;
    valid = WFFocusValidateMethod(service, "delegate", "@", @[]) && valid;
    valid = WFFocusValidateMethod(engine, "_queue_removeAllInflightMetadata", "v", @[]) && valid;
    valid = WFFocusValidateMethod(engine, "_queue_cancelInflightExpirationTimer", "B", @[]) && valid;
    valid = WFFocusValidateMethod(paired, "syncServiceType", "Q", @[]) && valid;
    valid = WFFocusValidateMethod(paired, "deviceIdentifier", "@", @[]) && valid;
    valid = WFFocusValidateMethod(record, "objectForKey:", "@", @[@"@"]) && valid;
    valid = WFFocusValidateMethod(record, "setObject:forKey:", "v", @[@"@", @"@"]) && valid;
    valid = WFFocusValidateMethod(record, "metadata", "@", @[]) && valid;
    valid = WFFocusValidateMethod(record, "copyWithZone:", "@", @[@"^{_NSZone=}"]) && valid;
    valid = WFFocusValidateMethod(metadata, "isEqual:", "B", @[@"@"]) && valid;
    valid = WFFocusValidateMethod(store, "setSyncDate:forRecordsMatchingMetadata:forPairedDeviceIdentifier:",
                                  "v", @[@"@", @"@", @"@"]) && valid;
    valid = WFFocusValidateMethod(context, "initWithDestination:partitionType:redactSensitiveData:contactProvider:applicationIdentifierMapper:",
                                  "@", @[@"Q", @"Q", @"B", @"@", @"@"]) && valid;
    valid = WFFocusValidateClassMethod(metadata, "newWithDictionaryRepresentation:context:",
                                       "@", @[@"@", @"@"]) && valid;
    const char *ivarNames[] = {"_pairedDevice", "_metadataStore"};
    for (NSUInteger index = 0; index < sizeof(ivarNames) / sizeof(ivarNames[0]); index++) {
        const char *name = ivarNames[index];
        Ivar ivar = class_getInstanceVariable(engine, name);
        const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
        BOOL present = ivar && type && type[0] == '@';
        Log(@"[FocusCompatProbe] ivar=%s type=%s present=%@", name, type ?: "<missing>", present ? @"YES" : @"NO");
        valid = present && valid;
    }
    Ivar queue = class_getInstanceVariable(engine, "_queue");
    Ivar syncService = class_getInstanceVariable(engine, "_syncService");
    const char *queueType = queue ? ivar_getTypeEncoding(queue) : NULL;
    const char *serviceType = syncService ? ivar_getTypeEncoding(syncService) : NULL;
    BOOL queueValid = queueType && strcmp(queueType, "@\"NSObject<OS_dispatch_queue>\"") == 0;
    BOOL serviceValid = serviceType && strcmp(serviceType, "@\"<DNDSSyncService>\"") == 0;
    Log(@"[FocusCompatProbe] owner queue contract=%@ syncService link=%@",
        queueValid ? @"YES" : @"NO", serviceValid ? @"YES" : @"NO");
    valid = queueValid && serviceValid && valid;
    return valid;
}

static void WFFocusInstall(void) {
    if (IOSMajorVersion() != 15 || IOSMinorVersion() != 4 || IOSPatchVersion() != 0) {
        Log(@"[FocusCompatProbe] skipped: real OS is not exactly 15.4.0");
        return;
    }
    NSString *daemonPath = NSBundle.mainBundle.executablePath;
    if (!WFFocusImageMatches(daemonPath.fileSystemRepresentation, kWFFocusDaemonUUID, @"daemon")) return;
    Class service = objc_lookUpClass("DNDSIDSSyncService");
    Class engine = objc_lookUpClass("DNDSIDSSyncEngine");
    if (!service || !engine ||
        !WFFocusImageMatches(class_getImageName(service), kWFFocusFrameworkUUID, @"framework") ||
        !WFFocusImageMatches(class_getImageName(engine), kWFFocusFrameworkUUID, @"framework")) return;

    BOOL valid = YES;
    valid = WFFocusValidateMethod(service, "sendMessage:withVersionNumber:messageType:toDestinations:identifyingCompletionHandler:",
                                  "v", @[@"@", @"Q", @"@", @"@", @"@?"]) && valid;
    valid = WFFocusValidateMethod(service, "_queue_handleIncomingMessage:deviceIdentifier:",
                                  "v", @[@"@", @"@"]) && valid;
    valid = WFFocusValidateMethod(engine, "_queue_handleAckMessage:fromPairedDeviceIdentifier:",
                                  "v", @[@"@", @"@"]) && valid;
    if (!valid) {
        Log(@"[FocusCompatProbe] observers disabled: exact identity/ABI/ownership mismatch; no retry");
        return;
    }
    WFFocusFullContractsValid = WFFocusValidateFullContracts(service, engine);
    Log(@"[FocusCompatProbe] schema=hd-offline1 readonlyBuild=%d full conversion contracts=%@; behavior override default=%@",
        WF_FOCUS_READONLY_BUILD, WFFocusFullContractsValid ? @"YES" : @"NO",
        WFFocusHooksEnabled() ? @"ENABLED" : @"DISABLED");
    MSHookMessageEx(service, sel_registerName("sendMessage:withVersionNumber:messageType:toDestinations:identifyingCompletionHandler:"),
                    (IMP)WFFocusSend, &WFFocusOriginalSend);
    MSHookMessageEx(service, sel_registerName("_queue_handleIncomingMessage:deviceIdentifier:"),
                    (IMP)WFFocusIncoming, &WFFocusOriginalIncoming);
    MSHookMessageEx(engine, sel_registerName("_queue_handleAckMessage:fromPairedDeviceIdentifier:"),
                    (IMP)WFFocusAck, &WFFocusOriginalAck);
    if (!WFFocusOriginalSend || !WFFocusOriginalIncoming || !WFFocusOriginalAck) {
        Log(@"[FocusCompatProbe] installation failed: missing original IMP");
        return;
    }
    Log(@"[FocusCompatProbe] PASS observers installed; readonlyBuild=%d", WF_FOCUS_READONLY_BUILD);
}

#ifndef WF_FOCUS_PROBE_HOST_TEST
%ctor {
    const char *program = getprogname();
    if (!program || strcmp(program, "donotdisturbd") != 0) return;
    syslog(LOG_WARNING, "[WatchFix][FocusConfigCompatibility] schema=hd-offline1 readonlyBuild=%d constructor entered pid=%d", WF_FOCUS_READONLY_BUILD, getpid());
    @autoreleasepool {
        WFFocusInstall();
    }
}
#endif
