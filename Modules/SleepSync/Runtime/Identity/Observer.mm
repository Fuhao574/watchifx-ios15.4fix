// Default-disabled identity shadow: preserve the original Hello and its output.
// A candidate is returned only after route, full-field, native encode/decode and
// original-stability checks all pass. No payload logging or direct byte edits.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <atomic>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <time.h>
#include <pthread.h>
#include <os/log.h>
#include "ExecutableGate.h"
#ifndef WF_OBSERVER_HOST_TEST
#include <substrate.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <ptrauth.h>
#include <roothide.h>
#include <unistd.h>
#include "IdentityLog.h"
#include "ModuleSession.h"
static WFWirelessIdentity::Writer WFPrivateLog;
static void WFPrivateEvent(const char *event,unsigned int seq,unsigned int depth,unsigned int count,unsigned int route,unsigned int detail,bool returned,double uptime) {
    @try {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ const char *path=WFModuleDirectory("identity"); WFPrivateLog.Open(path); });
        WFPrivateLog.Event(event,seq,depth,count,route,detail,returned,uptime);
    } @catch(NSException *ignored) {(void)ignored;}
}
#endif

@interface IDSUTunControlMessage_Hello : NSObject
- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length loggingPrefixString:(NSString *)prefix;
@end

static constexpr unsigned int kMaxCallbacks = 32;
static constexpr unsigned int kMaxDataPerCallback = 8;
static constexpr unsigned int kMaxLogs = 160;
static constexpr double kWindowSeconds = 600.0;
static std::atomic<unsigned int> WFCallbacks{0};
static std::atomic<unsigned int> WFLogs{0};
static std::atomic<bool> WFExpiredLogged{false};
static double WFStart;
static Class WFHelloClass;
static Class WFInfoClass;
static NSString *WFDefaultRoute;
static IMP WFOriginalConnect;
static IMP WFOriginalData;
static IMP WFInfoCBUUID;
static std::atomic<bool> WFNeutralAttempted{false};
static std::atomic<bool> WFIdentityAttempted{false};
static bool WFNeutralContractReady;

static bool WFIdentityEnabled(void) {
#ifdef WF_OBSERVER_HOST_TEST
    extern bool WFTestIdentityEnabled;
    return WFTestIdentityEnabled;
#else
    bool enabled=WFModuleIdentityEnabled();
    WFPrivateEvent("identity-config",0,0,0,0,enabled?3u:1u,false,NSProcessInfo.processInfo.systemUptime);
    return enabled;
#endif
}

enum WFRoute : unsigned int { WFRouteUnknown = 0, WFRouteOther = 1, WFRouteDefault = 2 };
enum WFResult : unsigned int { WFResultNil = 0, WFResultData = 1, WFResultOther = 2 };

struct WFFrame {
    WFFrame *previous;
    unsigned int sequence;
    unsigned int depth;
    unsigned int dataCalls;
    WFRoute route;
    bool observed;
    bool inspecting;
    bool connectionOK;
};
static thread_local WFFrame *WFCurrent;

#ifdef WF_OBSERVER_HOST_TEST
static double WFTestNow;
static bool WFTestFailClock;
static unsigned int WFTestLogCount;
static void (*WFTestLogSink)(const char *, unsigned int, bool);
#endif

static double WFNow() {
#ifdef WF_OBSERVER_HOST_TEST
    return WFTestFailClock ? -1.0 : WFTestNow;
#else
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) return -1.0;
    return (double)time.tv_sec + (double)time.tv_nsec / 1.0e9;
#endif
}

static bool WFActive() {
    double now = WFNow();
    return WFStart >= 0.0 && now >= WFStart && now - WFStart < kWindowSeconds;
}

static void WFLog(const char *event, unsigned int seq, unsigned int depth,
                  unsigned int count, WFRoute route, unsigned int detail, bool returned) {
    // Fixed labels/numeric metadata only. No %@, object descriptions, addresses,
    // UUIDs, build/version values, message lengths or payload contents.
    if (WFLogs.fetch_add(1, std::memory_order_relaxed) >= kMaxLogs) return;
#ifdef WF_OBSERVER_HOST_TEST
    (void)event; (void)seq; (void)depth; (void)count; (void)route; (void)detail; (void)returned;
    WFTestLogCount++;
    if (WFTestLogSink) WFTestLogSink(event, detail, returned);
#else
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT,
        "[WFHelloNeutral2] event=%{public}s seq=%{public}u depth=%{public}u count=%{public}u route=%{public}u detail=%{public}u returned=%{public}d tid=%{public}llu",
        event, seq, depth, count, (unsigned int)route, detail, returned, (unsigned long long)tid);
    WFPrivateEvent(event,seq,depth,count,(unsigned int)route,detail,returned,NSProcessInfo.processInfo.systemUptime);
#endif
}

static void WFLogExpired() {
    if (!WFExpiredLogged.exchange(true)) WFLog("window-expired", 0, 0, 0, WFRouteUnknown, 0, false);
}

static WFRoute WFReadRoute(id info) {
    if (!info || object_getClass(info) != WFInfoClass || !WFDefaultRoute || !WFInfoCBUUID)
        return WFRouteUnknown;
    @try {
        // Exact ABI/owner/IMP for this side-effect-free connection-info getter
        // is checked before installation. Its value is compared, never logged.
        id route = ((id (*)(id, SEL))WFInfoCBUUID)(info, sel_registerName("cbuuid"));
        if (![route isKindOfClass:[NSString class]]) return WFRouteUnknown;
        return [(NSString *)route isEqualToString:WFDefaultRoute] ? WFRouteDefault : WFRouteOther;
    } @catch (NSException *exception) {
        (void)exception;
        return WFRouteUnknown;
    }
}

static WFResult WFClassifyResult(id result) {
    if (!result) return WFResultNil;
    @try {
        return [result isKindOfClass:[NSData class]] ? WFResultData : WFResultOther;
    } @catch (NSException *exception) {
        (void)exception;
        return WFResultOther;
    }
}

static void WFCompareNeutral(id source, id originalResult, WFFrame *frame);
static id WFIdentityCandidate(id source, id originalResult, WFFrame *frame);

static void WFObserveConnect(id self, SEL selector, id info, id connection, id error) {
    // Even a non-observed nested callback masks the outer scope. Never let a
    // callback beyond limits inherit an outer callback's permission/context.
    WFFrame frame = {WFCurrent, 0, WFCurrent ? WFCurrent->depth + 1 : 1,
                     0, WFRouteUnknown, false, false, connection != nil && error == nil};
    bool withinWindow = WFActive();
    if (withinWindow && frame.depth <= 8) {
        unsigned int index = WFCallbacks.fetch_add(1, std::memory_order_relaxed);
        frame.sequence = index + 1;
        frame.observed = index < kMaxCallbacks;
    } else if (!withinWindow) {
        WFLogExpired();
    }
    WFCurrent = &frame;
    bool returned = false;
    @try {
        if (frame.observed) {
            frame.inspecting = true;
            frame.route = WFReadRoute(info);
            frame.inspecting = false;
            // detail bits: connection present, error present, exact info class.
            unsigned int flags = (connection ? 1u : 0u) | (error ? 2u : 0u) |
                                 (info && object_getClass(info) == WFInfoClass ? 4u : 0u);
            WFLog("connect-enter", frame.sequence, frame.depth, 0, frame.route, flags, false);
        }
        // Exactly once; original arguments unchanged. No catch around original.
        ((void (*)(id, SEL, id, id, id))WFOriginalConnect)(self, selector, info, connection, error);
        returned = true;
    } @finally {
        WFCurrent = frame.previous;
        if (frame.observed)
            WFLog("connect-exit", frame.sequence, frame.depth, frame.dataCalls, frame.route, 0, returned);
    }
}

static id WFObserveData(id self, SEL selector) {
    WFFrame *frame = WFCurrent;
    bool active = WFActive();
    bool observed = active && frame && frame->observed && !frame->inspecting &&
                    frame->dataCalls < kMaxDataPerCallback;
    unsigned int count = 0;
    if (observed) {
        count = ++frame->dataCalls;
        WFLog("data-enter", frame->sequence, frame->depth, count, frame->route,
              object_getClass(self) == WFHelloClass ? 1u : 0u, false);
    }
    if (!active) WFLogExpired();
    bool returned = false;
    id result = nil;
    @try {
        // Original exactly once. Original exceptions must never be swallowed by
        // the optional neutral probe, and the result below must not be replaced.
        result = ((id (*)(id, SEL))WFOriginalData)(self, selector);
        returned = true;
        if (observed && count == 1 && frame->depth == 1 && frame->connectionOK && frame->route == WFRouteDefault &&
            object_getClass(self) == WFHelloClass && WFNeutralContractReady &&
            WFClassifyResult(result) == WFResultData && WFActive()) {
            bool expected = false;
            if (WFIdentityEnabled()) {
                if (WFIdentityAttempted.compare_exchange_strong(expected, true)) {
                    bool oldInspecting = frame->inspecting;
                    frame->inspecting = true;
                    @try {
                        id candidate = WFIdentityCandidate(self, result, frame);
                        if (candidate) return candidate;
                    } @catch (NSException *exception) {
                        (void)exception;
                        WFLog("identity-failed", frame->sequence, frame->depth, 1, frame->route, 99, false);
                    } @finally {
                        frame->inspecting = oldInspecting;
                    }
                }
            } else if (WFNeutralAttempted.compare_exchange_strong(expected, true)) {
                bool oldInspecting = frame->inspecting;
                frame->inspecting = true;
                @try {
                    WFCompareNeutral(self, result, frame);
                } @catch (NSException *exception) {
                    (void)exception;
                    WFLog("neutral-failed", frame->sequence, frame->depth, 1, frame->route, 99, false);
                } @finally {
                    frame->inspecting = oldInspecting;
                }
            }
        }
        return result;
    } @finally {
        if (observed) {
            bool oldInspecting = frame->inspecting;
            frame->inspecting = true;
            WFResult kind = returned ? WFClassifyResult(result) : WFResultNil;
            frame->inspecting = oldInspecting;
            WFLog("data-exit", frame->sequence, frame->depth, count, frame->route, kind, returned);
        }
    }
}

static bool WFABI(Method method, const char *returnType, unsigned int argumentCount) {
    if (!method || method_getNumberOfArguments(method) != argumentCount) return false;
    char *type = method_copyReturnType(method);
    bool valid = type && strcmp(type, returnType) == 0;
    free(type);
    for (unsigned int i = 0; i < argumentCount; i++) {
        type = method_copyArgumentType(method, i);
        const char *expected = i == 1 ? ":" : "@";
        valid = valid && type && strcmp(type, expected) == 0;
        free(type);
    }
    return valid;
}

#ifndef WF_OBSERVER_HOST_TEST
static bool WFOwned(Class cls, Method method, const struct mach_header_64 *header,
                    const char *path, uintptr_t offset);
#endif
#include "NeutralCopy.h"

#ifndef WF_OBSERVER_HOST_TEST
static bool WFInstalled;
static unsigned int WFAttempts;

static unsigned int WFHost(const struct mach_header_64 **headerOut, const char **pathOut) {
    const char *program = getprogname();
    if (!program || strcmp(program, "identityservicesd") != 0) return 10;
    Class native = objc_lookUpClass("IDSUTunController");
    if (!native) return 11;
    const char *owner = class_getImageName(native);
    if (!WFBaseNameMatches(owner, "identityservicesd")) return 12;
    // Never assume injected process dyld image 0 is the executable. Select the
    // defining image of a native class; still require MH_EXECUTE/arm64e/UUID.
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path || strcmp(path, owner) != 0) continue;
        const struct mach_header *raw = _dyld_get_image_header(i);
        if (!raw || raw->magic != MH_MAGIC_64) return 1;
        auto *h = (const struct mach_header_64 *)raw;
        if (h->sizeofcmds > 1024 * 1024) return 2;
        unsigned int reason = WFValidateExecutable(h, sizeof(*h) + h->sizeofcmds);
        if (reason) return reason;
        WFLog("host-matched", 0, 0, i, WFRouteUnknown, h->filetype, true);
        *headerOut = h;
        *pathOut = path;
        return 0;
    }
    return 13;
}

static bool WFOwned(Class cls, Method method, const struct mach_header_64 *header,
                    const char *path, uintptr_t offset) {
    const char *owner = cls ? class_getImageName(cls) : NULL;
    if (!owner || strcmp(owner, path) != 0 || !method) return false;
    void *implementation = ptrauth_strip((void *)method_getImplementation(method), ptrauth_key_function_pointer);
    return (uintptr_t)implementation == (uintptr_t)header + offset;
}

static void WFInstall() {
    if (WFInstalled || WFAttempts >= 12) return;
    WFAttempts++;
    const struct mach_header_64 *header = NULL;
    const char *path = NULL;
    unsigned int hostReason = WFHost(&header, &path);
    if (hostReason) {
        bool retry = hostReason == 11 || hostReason == 13;
        WFLog(retry ? "retry-host-image" : "disabled-host", 0, 0, WFAttempts, WFRouteUnknown, hostReason, false);
        if (retry && WFAttempts < 12)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ WFInstall(); });
        return;
    }
    Class controller = objc_lookUpClass("IDSUTunController");
    Class hello = objc_lookUpClass("IDSUTunControlMessage_Hello");
    Class info = objc_lookUpClass("IDSDeviceConnectionInfo");
    if (!controller || !hello || !info) {
        WFLog("retry-classes", 0, 0, WFAttempts, WFRouteUnknown, 0, false);
        if (WFAttempts < 12)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ WFInstall(); });
        return;
    }
    SEL connectSelector = sel_registerName("didConnectControlChannelForDeviceConnectionInfo:connection:error:");
    SEL dataSelector = sel_registerName("data");
    Method connectMethod = class_getInstanceMethod(controller, connectSelector);
    Method dataMethod = class_getInstanceMethod(hello, dataSelector);
    Method routeMethod = class_getInstanceMethod(info, sel_registerName("cbuuid"));
    if (!WFABI(connectMethod, "v", 5) || !WFABI(dataMethod, "@", 2) || !WFABI(routeMethod, "@", 2) ||
        !WFOwned(controller, connectMethod, header, path, 0x54C480) ||
        !WFOwned(hello, dataMethod, header, path, 0x1760FC) ||
        !WFOwned(info, routeMethod, header, path, 0x026A5C)) {
        WFLog("disabled-contract", 0, 0, 0, WFRouteUnknown, 0, false);
        return;
    }
    // Resolve existing exported constant only; no dlopen or private API request.
    auto *constant = (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, "kIDSDefaultPairedDeviceID");
    Dl_info owner = {};
    if (!constant || !dladdr((const void *)constant, &owner) || !owner.dli_fname ||
        !strstr(owner.dli_fname, "/IDSFoundation.framework/")) {
        WFLog("disabled-route-symbol", 0, 0, 0, WFRouteUnknown, 0, false);
        return;
    }
    @try {
        id value = *constant;
        if (![value isKindOfClass:[NSString class]]) {
            WFLog("disabled-route-type", 0, 0, 0, WFRouteUnknown, 0, false);
            return;
        }
        WFDefaultRoute = value;
    } @catch (NSException *exception) {
        (void)exception;
        WFLog("disabled-route-type", 0, 0, 0, WFRouteUnknown, 0, false);
        return;
    }
    WFInfoClass = info;
    WFHelloClass = hello;
    WFInfoCBUUID = method_getImplementation(routeMethod);
    WFNeutralContractReady = WFPrepareNeutralContract(header, path);
    if (!WFNeutralContractReady) {
        WFLog("disabled-neutral-contract", 0, 0, 0, WFRouteUnknown, 0, false);
        return;
    }
    WFStart = WFNow();
    if (WFStart < 0) {
        WFLog("disabled-clock", 0, 0, 0, WFRouteUnknown, 0, false);
        return;
    }
    // Data installed first: until callback is installed it simply forwards.
    MSHookMessageEx(hello, dataSelector, (IMP)WFObserveData, &WFOriginalData);
    if (!WFOriginalData) {
        WFLog("install-failed-data", 0, 0, 0, WFRouteUnknown, 0, false);
        return;
    }
    MSHookMessageEx(controller, connectSelector, (IMP)WFObserveConnect, &WFOriginalConnect);
    WFInstalled = WFOriginalConnect != NULL;
    WFLog(WFInstalled ? "installed-neutral" : "install-failed-connect", 0, 0, 0, WFRouteUnknown, 0, false);
}

__attribute__((constructor)) static void WFLoadObserver() {
    @autoreleasepool {
        WFLog("load-identity-wireless1", 0, 0, 0, WFRouteUnknown, 0, false);
        WFInstall();
    }
}
#endif
