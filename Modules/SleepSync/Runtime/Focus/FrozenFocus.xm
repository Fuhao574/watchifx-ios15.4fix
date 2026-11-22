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
#include <math.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif
#include "utils.h"
#include "PluginConfig.h"
#include "FocusWireConverter.h"

extern BOOL WFTrialEnabled(void);
extern void WFTrialInitialize(void);
extern void WFTrialSetHooksReady(BOOL);
extern BOOL WFTrialPolicyReady(void);
extern BOOL WFTrialClaimReceipt(NSString *, BOOL);
static IMP WFFocusOriginalSend;
static IMP WFFocusOriginalIncoming;
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
static char kWFSleepReturnContextKey;
#include "SleepReturnObservation.h"
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

// Separate immutable context survives ACK clearing the short transaction.
// It expires independently and cannot authorize another send or native import.
@interface WFSleepReturnContext : NSObject
@property(nonatomic,readonly,strong) WFFocusRouteSnapshot *route;
@property(nonatomic,readonly,copy) NSDictionary *publicModel;
@property(nonatomic,readonly,copy) NSDictionary *secureModel;
- (instancetype)initWithRoute:(WFFocusRouteSnapshot *)route public:(NSDictionary *)pub secure:(NSDictionary *)sec;
@end
@implementation WFSleepReturnContext
- (instancetype)initWithRoute:(WFFocusRouteSnapshot *)route public:(NSDictionary *)pub secure:(NSDictionary *)sec {
    if ((self=[super init])) {_route=route;_publicModel=[pub copy];_secureModel=[sec copy];}
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
    return WFTrialEnabled();
#else
    return WFTrialEnabled();
#endif
}

static NSTimeInterval WFFocusUptime(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

static BOOL WFFocusConsumeExperimentPermit(void) {
#if defined(WF_FOCUS_PROBE_HOST_TEST) && !WF_FOCUS_READONLY_BUILD
    extern BOOL WFFocusTestPermitAllowed;
    return WFTrialClaimReceipt(@"policy-spent", YES);
#else
    return WFTrialClaimReceipt(@"policy-spent", YES);
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
        id safeKey = [@[@"h", @"d", @"v", @"r", @"y", @"t", @"action", @"ackAction", @"metadataAck", @"syncDate", @"modifiedRecords", @"deletedMetadata"] containsObject:key] ? key : @"<other-key>";
        NSString *type = @"other";
        if ([value isKindOfClass:[NSString class]]) type = @"string";
        else if ([value isKindOfClass:[NSNumber class]]) type = @"number";
        else if ([value isKindOfClass:[NSData class]]) type = @"data";
        else if ([value isKindOfClass:[NSArray class]]) type = @"array";
        else if ([value isKindOfClass:[NSDictionary class]]) type = @"dict";
        else if ([value isKindOfClass:[NSNull class]]) type = @"null";
        [parts addObject:[NSString stringWithFormat:@"%@:%@", safeKey, type]];
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

static BOOL WFSleepOnceStrictMetadata(id metadata) {
    if (![metadata isKindOfClass:[NSDictionary class]] || [metadata count]!=3) return NO;
    id recordID=metadata[@"recordID"], modified=metadata[@"lastModified"], deleted=metadata[@"deleted"];
    if (![recordID isKindOfClass:[NSDictionary class]] || [recordID count]!=2 ||
        ![recordID[@"identifier"] isKindOfClass:[NSString class]] || ![recordID[@"identifier"] length] ||
        ![recordID[@"zone"] isKindOfClass:[NSString class]] || ![recordID[@"zone"] length] ||
        ![modified isKindOfClass:[NSNumber class]] || ![deleted isKindOfClass:[NSNumber class]]) return NO;
    double timestamp=[modified doubleValue];
    return CFGetTypeID((__bridge CFTypeRef)modified)!=CFBooleanGetTypeID() &&
        isfinite(timestamp) && timestamp>=0 &&
        ([deleted isEqualToNumber:@0] || [deleted isEqualToNumber:@1]);
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

static BOOL WFFocusValidateMethod(Class, const char *, const char *, NSArray *);
// Policy-only: no control-upgrade or acceptance-override hook.

static BOOL WFFocusTryConvertedSend(id service, SEL selector, id message, NSUInteger version,
                                    id messageType, id destinations, id completion) {
    if (!WFFocusHooksEnabled() || version != 10 || ![messageType isKindOfClass:[NSString class]] ||
        ![messageType isEqualToString:@"syncEngine"] ||
        ![message isKindOfClass:[NSDictionary class]]) return NO;
    NSString *action = [message[@"action"] isKindOfClass:[NSString class]] ? message[@"action"] : nil;
    BOOL policyBatch = [action isEqualToString:@"update"] || [action isEqualToString:@"replace"];
    BOOL control = [action isEqualToString:@"resync"] || [action isEqualToString:@"unlock"];
    if (control || !policyBatch) return NO; // Native control stays original v10.
    NSString *pairedIdentifier = nil;
    id engine = WFFocusLocalEngine(service, destinations, &pairedIdentifier);
    if (!engine || !WFTrialPolicyReady()) return NO;
    if (!WFFocusFullContractsValid) {
        Log(@"[FocusCompat] NO extra send for native %@: full runtime contracts are unavailable", action);
        return NO; // No experiment ownership; preserve original native send.
    }
    WFFocusTransaction *existing = WFFocusCurrentTransaction(engine);
    if (atomic_load_explicit(&WFFocusPolicySendClaimed, memory_order_relaxed)) {
        Log(@"[FocusCompat] NO extra send for native %@: process policy-send budget already consumed", action);
        return NO; // No experiment ownership; preserve original native send.
    }
    if (existing) {
        Log(@"[FocusCompat] duplicate native %@ suppressed while custom update awaits ACK", action);
        return NO; // No experiment ownership; preserve original native send.
    }

    NSDictionary *converted = nil;
    BOOL nativeSendStarted = NO;
    @try {
        NSError *conversionError = nil;
        // User scope: one Sleep record only; unrelated modes are not sent.
        if ([action isEqual:@"replace"]) {
            NSDictionary *plan = WFFocusPlanIndependentSleepUpdate(message, &conversionError);
            converted = plan[@"candidateMessage"];
        } else if ([message[@"modifiedRecords"] isKindOfClass:[NSArray class]] &&
                   [message[@"modifiedRecords"] count]==1 &&
                   [message[@"deletedMetadata"] isKindOfClass:[NSArray class]] &&
                   [message[@"deletedMetadata"] count]==0) {
            converted = WFFocusConvertSleepMessage(message, &conversionError);
        }
        if (!converted) {
            Log(@"[FocusCompat] NO extra send for native %@: conversion refused code=%ld", action, (long)conversionError.code);
            return NO; // Rejected before original v11 send, leave native v10 intact.
        }
        // Source is sampled AFTER native send returns. Deep-freeze that
        // return-time candidate so metadata cannot mutate while service queues it.
        NSData *frozenBytes=[NSPropertyListSerialization dataWithPropertyList:converted format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        if (!frozenBytes.length || frozenBytes.length>4*1024*1024) return NO;
        converted=[NSPropertyListSerialization propertyListWithData:frozenBytes options:NSPropertyListImmutable format:NULL error:nil];
        if (![converted isKindOfClass:[NSDictionary class]]) return NO;
        id record = [converted[@"modifiedRecords"] firstObject];
        id expectedMetadata = nil;
        if ([record isKindOfClass:[NSDictionary class]]) {
            id representation = record[@"metadata"];
            if ([representation isKindOfClass:[NSDictionary class]]) {
                NSArray *parsed = WFSleepOnceStrictMetadata(representation) ? WFFocusNativeMetadataObjects(@[representation]) : nil;
                if (parsed.count == 1) expectedMetadata = parsed[0];
            }
        } else if ([record respondsToSelector:@selector(metadata)]) {
            expectedMetadata = [record metadata];
        }
        if (!expectedMetadata) {
            Log(@"[FocusCompat] BLOCK converted update: native record metadata is unavailable");
            return NO; // Rejected before original v11 send, leave native v10 intact.
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
            Log(@"[FocusCompat] NO extra send for native %@: policy-send budget lost to another caller", action);
            return NO; // Rejected before original v11 send, leave native v10 intact.
        }
        if (!WFFocusConsumeExperimentPermit()) {
            Log(@"[FocusCompat] BLOCK policy send: no audited durable experiment permit");
            return NO; // Rejected before original v11 send, leave native v10 intact.
        }

        // No broad inflight clear: ownership of native batch bookkeeping is
        // not acquired or needed by the additive experiment.
        // Native upstream metadata and retry state remain normal native business behavior.
        objc_setAssociatedObject(engine, &kWFFocusTransactionAssociationKey, transaction,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        WFFocusRouteSnapshot *route = [[WFFocusRouteSnapshot alloc] initWithEngine:engine
            queue:WFFocusEngineQueue(engine) peer:pairedIdentifier deadline:transaction.expiresAtUptime];
        transaction.route = route;
        NSDictionary *recordData=[transaction.message[@"modifiedRecords"] firstObject][@"data"];
        NSDictionary *expectedPublic=[NSJSONSerialization JSONObjectWithData:recordData[@"DNDSModeConfigurationsRecordData"] options:0 error:nil];
        NSDictionary *expectedSecure=[NSJSONSerialization JSONObjectWithData:recordData[@"DNDSModeConfigurationsRecordPartitionedData"] options:0 error:nil];
        if (![expectedPublic isKindOfClass:[NSDictionary class]] || ![expectedSecure isKindOfClass:[NSDictionary class]]) {
            WFFocusClearTransaction(engine,transaction);return NO;
        }
        WFSleepReturnContext *returnContext=[[WFSleepReturnContext alloc] initWithRoute:route public:expectedPublic secure:expectedSecure];
        objc_setAssociatedObject(service,&kWFSleepReturnContextKey,returnContext,OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(service, &kWFFocusRouteAssociationKey, route, OBJC_ASSOCIATION_RETAIN);
        __weak id weakEngine = engine;
        __weak WFFocusTransaction *weakTransaction = transaction;
        void (^customCompletion)(BOOL, id, id) = ^(BOOL success, id requestIdentifier, id error) {
            (void)requestIdentifier;
            WFFocusTransportCompletion(weakEngine, weakTransaction, success, error);
        };
        @try {
            Log(@"[FocusCompat] SLEEPMODULE1 adding ONE Sleep v11 update; original native batch/completion preserved");
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
        return NO; // No experiment ownership; preserve original native send.
    }
}

// Read-only observer on the engine queue. Native incoming messages are NEVER
// rewritten/tagged and no native ACK handler or persistent writer is invoked.
static void WFSleepOnceObserveAck(id engine,WFFocusRouteSnapshot *route,NSDictionary *body,NSString *peer) {
    if (!WFFocusOnEngineQueue(engine) || !WFFocusHooksEnabled() || !WFFocusFullContractsValid) return;
    WFFocusTransaction *pending=WFFocusCurrentTransaction(engine);
    if (!pending || pending.route!=route || route.engine!=engine ||
        objc_getAssociatedObject(pending.service,&kWFFocusRouteAssociationKey)!=route ||
        ![route.peer isEqual:peer] || route.deadline<=WFFocusUptime() ||
        ![WFFocusLocalPeerOnOwner(engine,pending.service) isEqual:peer]) return;
    if (![body[@"action"] isEqual:@"ack"] || ![body[@"ackAction"] isEqual:@"update"] ||
        ![body[@"metadataAck"] isKindOfClass:[NSArray class]] || [body[@"metadataAck"] count]!=1 ||
        !WFSleepOnceStrictMetadata([body[@"metadataAck"] firstObject]) ||
        ![body[@"syncDate"] isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)body[@"syncDate"])==CFBooleanGetTypeID()) return;
    double date=[body[@"syncDate"] doubleValue];
    if (!isfinite(date) || date<0) return;
    NSArray *parsed=WFFocusNativeMetadataObjects(body[@"metadataAck"]);
    if (parsed.count!=1 || ![pending.expectedMetadata isEqual:parsed[0]]) return;
    Log(@"[FocusCompat] SLEEPMODULE1 real v11/12 ACK metadata matched; observation only, native acceptance/storage and transaction causality unverified");
    WFFocusClearTransaction(engine,pending);
}

static unsigned int WFSleepReturnLogCount;
static void WFSleepLogReturn(id service,WFSleepReturnContext *context,NSDictionary *summary,NSString *peer) {
    id engine=context.route.engine;
    if (!engine || !WFFocusOnEngineQueue(engine) || !WFFocusHooksEnabled() ||
        context.route.deadline<=WFFocusUptime() ||
        objc_getAssociatedObject(service,&kWFSleepReturnContextKey)!=context ||
        [service delegate]!=engine || ![context.route.peer isEqual:peer] ||
        ![WFFocusLocalPeerOnOwner(engine,service) isEqual:peer] || WFSleepReturnLogCount>=3) return;
    ++WFSleepReturnLogCount;
    // Fixed keys/scalars from the closed summary schema; no raw user objects.
    Log(@"[FocusCompat] WATCH-SLEEP-EXPORT status=%@ reason=%@ contentPresent=%@ content=%@ appPresent=%@ app=%@ senderPresent=%@ sender=%@ suppressionModePresent=%@ suppressionMode=%@ hasSecureDataPresent=%@ hasSecureData=%@ scalarProjection=%@ suppressionModeComparison=%@ configurationEqual=%@ appsEqual=%@ platformsEqual=%@ senderEqual=%@ publicEqual=%@ secureEqual=%@ secureSemantics=UNKNOWN; export-view only NOT disk/resolver proof",
        summary[@"status"],summary[@"reason"],summary[@"observedContentCompatibilityPresent"],summary[@"observedContentCompatibility"],
        summary[@"applicationConfigurationTypePresent"],summary[@"applicationConfigurationType"],summary[@"senderConfigurationTypePresent"],summary[@"senderConfigurationType"],
        summary[@"suppressionModePresent"],summary[@"suppressionMode"],summary[@"hasSecureDataPresent"],summary[@"hasSecureData"],
        summary[@"configurationScalarsComparisonStatus"],summary[@"suppressionModeComparisonStatus"],summary[@"configurationComparisonStatus"],summary[@"allowedAppsComparisonStatus"],summary[@"platformsComparisonStatus"],summary[@"senderComparisonStatus"],
        summary[@"publicComparisonStatus"],summary[@"secureComparisonStatus"]);
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
    // Original native batch runs exactly once, with the original completion.
    // Only after that call returns may an explicitly armed additive send occur.
    ((void (*)(id, SEL, id, NSUInteger, id, id, id))WFFocusOriginalSend)
        (self, selector, message, version, messageType, destinations, completion);
    @try {
        (void)WFFocusTryConvertedSend(self,selector,message,version,messageType,destinations,nil);
    } @catch(NSException *ignored) {
        (void)ignored;
        Log(@"[FocusCompat] SLEEPMODULE1 additive attempt threw; native send already preserved, no retry");
    }
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
        Log(@"[FocusCompatProbe] inbound schema=sleep-module1 event=%u version=%@ type=%@ action=%@ ackAction=%@ metadataAck=%lu peerPresent=%@ shape=%@",
            event, version ?: @"missing", type, WFFocusAction(body[@"action"]),
            WFFocusAction(body[@"ackAction"]),
            (unsigned long)WFFocusCount(body[@"metadataAck"]), deviceIdentifier ? @"YES" : @"NO",
            WFFocusEnvelopeShape(message));
    }
    WFSleepReturnContext *returnContext=nil;
    NSDictionary *returnSummary=nil;
    @try {
        returnContext=objc_getAssociatedObject(self,&kWFSleepReturnContextKey);
        id h=[message isKindOfClass:[NSDictionary class]] ? message[@"h"]:nil;
        id d=[message isKindOfClass:[NSDictionary class]] ? message[@"d"]:nil;
        if ([returnContext isKindOfClass:[WFSleepReturnContext class]] && WFFocusHooksEnabled() &&
            returnContext.route.engine==[self delegate] && returnContext.route.deadline>WFFocusUptime() &&
            [deviceIdentifier isKindOfClass:[NSString class]] && [returnContext.route.peer isEqual:deviceIdentifier] &&
            [h isKindOfClass:[NSDictionary class]] && [h[@"y"] isEqual:@"syncEngine"] &&
            [d isKindOfClass:[NSDictionary class]] && [d[@"action"] isEqual:@"update"])
            returnSummary=WFSleepReturnObserve(message,returnContext.publicModel,returnContext.secureModel);
    } @catch(NSException *ignored) {(void)ignored;returnSummary=nil;}
    // Snapshot only potential new-wire ACK data, not live mutable transaction state.
    WFFocusRouteSnapshot *route=nil;
    NSDictionary *snapshot=nil;
    @try {
    route=objc_getAssociatedObject(self,&kWFFocusRouteAssociationKey);
    NSDictionary *header=[message isKindOfClass:[NSDictionary class]] ? message[@"h"]:nil;
    NSDictionary *body=[message isKindOfClass:[NSDictionary class]] ? message[@"d"]:nil;
    id version=[header isKindOfClass:[NSDictionary class]] ? header[@"r"]:nil;
    if (WFFocusHooksEnabled() && [route isKindOfClass:[WFFocusRouteSnapshot class]] &&
        route.engine && route.engine==[self delegate] &&
        [header isKindOfClass:[NSDictionary class]] && [header[@"y"] isEqual:@"syncEngine"] &&
        [version isKindOfClass:[NSNumber class]] &&
        CFGetTypeID((__bridge CFTypeRef)version)!=CFBooleanGetTypeID() &&
        ([version isEqual:@11] || [version isEqual:@12]) &&
        [body isKindOfClass:[NSDictionary class]] && [body[@"action"] isEqual:@"ack"] &&
        [body[@"ackAction"] isEqual:@"update"] && [deviceIdentifier isKindOfClass:[NSString class]] &&
        [route.peer isEqual:deviceIdentifier] &&
        [body[@"metadataAck"] isKindOfClass:[NSArray class]] && [body[@"metadataAck"] count]==1 &&
        WFSleepOnceStrictMetadata([body[@"metadataAck"] firstObject]) &&
        [body[@"syncDate"] isKindOfClass:[NSNumber class]]) {
        @try {
            // Snapshot only known ACK fields, never serialize arbitrary body data.
            NSDictionary *selected=@{@"action":@"ack",@"ackAction":@"update",@"metadataAck":body[@"metadataAck"],@"syncDate":body[@"syncDate"]};
            NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:selected format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
            if (bytes.length>0 && bytes.length<=65536)
                snapshot=[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:nil];
        } @catch(NSException *ignored) {(void)ignored;}
    }
    } @catch(NSException *ignored) {(void)ignored; snapshot=nil;}
    // Every native incoming message, including policy, v10/unknown and duplicate
    // ACKs, is forwarded once with exact original identity/version/peer unchanged.
    ((void (*)(id, SEL, id, id))WFFocusOriginalIncoming)(self,selector,message,deviceIdentifier);
    @try { if (returnSummary && returnContext.route.ownerQueue) {
        NSDictionary *captured=returnSummary;NSString *peer=[deviceIdentifier copy];
        dispatch_async(returnContext.route.ownerQueue, ^{@try {WFSleepLogReturn(self,returnContext,captured,peer);} @catch(NSException *ignored) {(void)ignored;}});
    }} @catch(NSException *ignored) {(void)ignored;}
    @try { if (snapshot && route.ownerQueue) {
        NSDictionary *captured=snapshot;NSString *peer=[deviceIdentifier copy];
        dispatch_async(route.ownerQueue, ^{@try {WFSleepOnceObserveAck(route.engine,route,captured,peer);} @catch(NSException *ignored) {(void)ignored;}});
    }} @catch(NSException *ignored) {(void)ignored;}
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

    Log(@"[FocusCompatProbe] schema=sleep-module1 readonlyBuild=%d full conversion contracts=%@; behavior override default=%@",
        WF_FOCUS_READONLY_BUILD, WFFocusFullContractsValid ? @"YES" : @"NO",
        WFFocusHooksEnabled() ? @"ENABLED" : @"DISABLED");
    MSHookMessageEx(service, sel_registerName("sendMessage:withVersionNumber:messageType:toDestinations:identifyingCompletionHandler:"),
                    (IMP)WFFocusSend, &WFFocusOriginalSend);
    MSHookMessageEx(service, sel_registerName("_queue_handleIncomingMessage:deviceIdentifier:"),
                    (IMP)WFFocusIncoming, &WFFocusOriginalIncoming);
    if (!WFFocusOriginalSend || !WFFocusOriginalIncoming) {
        Log(@"[FocusCompatProbe] installation failed: missing original IMP");
        return;
    }
    WFTrialSetHooksReady(WFFocusFullContractsValid);
    Log(@"[FocusCompatProbe] PASS policy-only hooks installed; enabled=%@ controlUpgrade=NO", WFTrialEnabled()?@"YES":@"NO");
}

#ifndef WF_FOCUS_PROBE_HOST_TEST
%ctor {
    const char *program = getprogname();
    if (!program || strcmp(program, "donotdisturbd") != 0) return;
    syslog(LOG_WARNING, "[WatchFix][FocusConfigCompatibility] schema=sleep-module1 readonlyBuild=%d constructor entered pid=%d", WF_FOCUS_READONLY_BUILD, getpid());
    @autoreleasepool {
        WFTrialInitialize();
        WFFocusInstall();
    }
}
#endif
