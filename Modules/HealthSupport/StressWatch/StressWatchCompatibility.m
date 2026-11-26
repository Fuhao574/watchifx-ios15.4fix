#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <CommonCrypto/CommonDigest.h>
#include <mach-o/dyld.h>
#include <ptrauth.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include "ImageIdentity.h"

// Phone app only. No query observer, health-data access, timers, logs, file IO,
// preference polling or Watch communication. Enablement is the external filter.
// Keep a once-written 16-byte state for bounded read-only verification only.
__attribute__((visibility("default"))) uint32_t WFHSStressWatchStatus[4];
static const uintptr_t WFBase = 0x100000000ULL;
static const uint8_t WFUUID[16] = {
    0x76,0x99,0xbd,0xc5,0xec,0xcd,0x34,0xa4,0x8f,0x29,0x72,0xdd,0xeb,0xcb,0x8d,0x64
};
typedef BOOL (*WFAcceptsValue)(id, SEL, int64_t);
typedef void (*WFHookMessage)(Class, SEL, IMP, IMP *);
typedef void (*WFHookMemory)(void *, const void *, size_t);
static WFAcceptsValue WFOriginalAccepts;

@protocol WFHSSleepType <NSObject>
- (NSInteger)code;
@end

static BOOL WFAcceptStage(id self, SEL selector, int64_t value) {
    if (value >= 3 && value <= 5 && [self respondsToSelector:@selector(code)] &&
        [(id<WFHSSleepType>)self code] == 63) return YES;
    return WFOriginalAccepts(self, selector, value);
}

static BOOL WFCodeMatches(uintptr_t base, uintptr_t preferred, size_t length, const char *hex) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256((const void *)(base + preferred - WFBase), (CC_LONG)length, digest);
    for (size_t i = 0; i < sizeof(digest); ++i) {
        unsigned expected = 0;
        for (size_t j = 0; j < 2; ++j) {
            char c = hex[2 * i + j];
            expected = expected * 16 + (c <= '9' ? c - '0' : c - 'a' + 10);
        }
        if (digest[i] != expected) return NO;
    }
    return YES;
}

static uintptr_t WFExactImage(void) {
    const struct mach_header_64 *matched = NULL;
    uint32_t count = _dyld_image_count();
    if (count > 4096) return 0;
    for (uint32_t i = 0; i < count; ++i) {
        const struct mach_header_64 *h = (const void *)_dyld_get_image_header(i);
        if (!WFHeaderMatches(h, WFUUID)) continue;
        if (matched && matched != h) return 0;
        matched = h;
    }
    Class cls = objc_lookUpClass("_TtC6Stress12SleepManager");
    Dl_info info = {0};
    if (cls && dladdr((__bridge const void *)cls, &info) &&
        WFHeaderMatches(info.dli_fbase, WFUUID)) {
        if (matched && matched != info.dli_fbase) return 0;
        matched = info.dli_fbase;
    }
    uintptr_t base = (uintptr_t)matched;
    if (!base || (uintptr_t)(__bridge const void *)cls != base + 0x19a4560) return 0;
    // Small immutable code windows, not the entire 29 MB commercial executable.
    if (!WFCodeMatches(base, 0x10060af68, 0x4c8, "2ffec69b41699bf2a4802f13a449672268f0ec44933925a21944809198f5d13e") ||
        !WFCodeMatches(base, 0x1009f23d0, 0x458, "9487fdcb83ce529fb9d10e4c1754a75875c0c17ec3293d15359dc9c832da1fa7") ||
        !WFCodeMatches(base, 0x1003ef23c, 0xa4, "41d2eb39d934a96c39a7165dbe73dc7536efa322ce8142a48a42d5db77e68faf")) return 0;
    return base;
}

__attribute__((constructor)) static void WFLoad(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.ideation.Stress"]) return;
        WFHSStressWatchStatus[0] = 1;
        char build[64] = {0}; size_t size = sizeof(build) - 1;
        if (sysctlbyname("kern.osversion", build, &size, NULL, 0) || strcmp(build, "19E241")) return;
        uintptr_t base = WFExactImage();
        if (!base) return; // Includes duplicate/legacy candidate code mismatch.
        WFHSStressWatchStatus[1] = 1;
        WFHookMemory patch = (WFHookMemory)dlsym(RTLD_DEFAULT, "MSHookMemory");
        WFHookMessage hook = (WFHookMessage)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
        Class cls = objc_lookUpClass("HKCategoryType");
        SEL accepts = sel_registerName("_acceptsValue:");
        Method method = cls ? class_getInstanceMethod(cls, accepts) : NULL;
        NSMethodSignature *sig = method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
        if (!patch || !hook || !sig || sig.numberOfArguments != 3 || sig.methodReturnLength != 1 ||
            (strcmp(sig.methodReturnType, "B") && strcmp(sig.methodReturnType, "c")) ||
            strcmp([sig getArgumentTypeAtIndex:2], "q")) return;
        // Pre-resolve the original to avoid a publication window in the hook.
        WFOriginalAccepts = (WFAcceptsValue)method_getImplementation(method);
        uint32_t *site = (void *)(base + 0x60afc8);
        const uint32_t replacement = 0x52800020;
        if (*site != 0x9435dc09) return;
        patch(site, &replacement, sizeof(replacement));
        if (*site != replacement) return;
        WFHSStressWatchStatus[2] = 1;
        IMP unusedTrampoline = NULL;
        hook(cls, accepts, (IMP)WFAcceptStage, &unusedTrampoline);
        WFHSStressWatchStatus[3] = class_getMethodImplementation(cls, accepts) == (IMP)WFAcceptStage;
    }
}
