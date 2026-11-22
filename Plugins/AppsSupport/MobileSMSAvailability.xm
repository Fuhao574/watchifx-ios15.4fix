#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <substrate.h>
#include <stdlib.h>
#include <string.h>
#include "utils.h"

// Experimental iOS 15-only fallback based on the device trace:
// local/system mappings include MobileSMS, while individual lookups fail
// with ACXErrorDomain 19. This does NOT intercept uninstall notifications,
// forge an ACX application object, or affect other bundle identifiers.
static IMP WFOriginalSystemAvailable;
static IMP WFOriginalCompanionBundle;

static BOOL WFShouldRepairMobileSMS(id bundleID, NSError *error) {
    return [bundleID isKindOfClass:[NSString class]] &&
           [bundleID isEqualToString:@"com.apple.MobileSMS"] &&
           [error.domain isEqualToString:@"ACXErrorDomain"] && error.code == 19;
}

static BOOL WFSystemAvailable(id self, SEL selector, id bundleID, NSError **error) {
    NSError *originalError = nil;
    BOOL available = ((BOOL (*)(id, SEL, id, NSError **))WFOriginalSystemAvailable)
        (self, selector, bundleID, &originalError);
    if (!available && WFShouldRepairMobileSMS(bundleID, originalError)) {
        if (error) *error = nil;
        Log(@"[SMSAvailability] iOS15 MobileSMS ACX19 availability fallback -> YES");
        return YES;
    }
    if (error && originalError) *error = originalError;
    return available;
}

static id WFCompanionBundle(id self, SEL selector, id bundleID, NSError **error) {
    NSError *originalError = nil;
    id counterpart = ((id (*)(id, SEL, id, NSError **))WFOriginalCompanionBundle)
        (self, selector, bundleID, &originalError);
    if (!counterpart && WFShouldRepairMobileSMS(bundleID, originalError)) {
        if (error) *error = nil;
        Log(@"[SMSAvailability] iOS15 MobileSMS ACX19 companion fallback -> MobileSMS");
        return @"com.apple.MobileSMS";
    }
    if (error && originalError) *error = originalError;
    return counterpart;
}

static BOOL WFAvailabilityABI(Method method, const char *returnType) {
    if (!method || method_getNumberOfArguments(method) != 4) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = type && strcmp(type, returnType) == 0;
    free(type);
    type = method_copyArgumentType(method, 2);
    valid = valid && type && type[0] == '@';
    free(type);
    type = method_copyArgumentType(method, 3);
    valid = valid && type && strcmp(type, "^@") == 0;
    free(type);
    return valid;
}

void WFInstallMobileSMSAvailabilityFix(void) {
    // PairingCompatibility spoofs NSProcessInfo; query the real OS via sysctl.
    if (IOSMajorVersion() != 15) {
        Log(@"[SMSAvailability] skipped (real OS is not iOS 15)");
        return;
    }
    Class cls = objc_lookUpClass("ACXAvailableApplicationManager");
    SEL available = sel_registerName("systemAppIsAvailableWithBundleID:error:");
    SEL counterpart = sel_registerName("companionBundleIDForLocallyAvailableSystemApp:error:");
    // Install as a pair only when both runtime contracts match the trace.
    if (!WFAvailabilityABI(class_getInstanceMethod(cls, available), "B") ||
        !WFAvailabilityABI(class_getInstanceMethod(cls, counterpart), "@")) {
        Log(@"[SMSAvailability] skipped: lookup methods missing or ABI mismatch");
        return;
    }
    MSHookMessageEx(cls, available, (IMP)WFSystemAvailable, &WFOriginalSystemAvailable);
    MSHookMessageEx(cls, counterpart, (IMP)WFCompanionBundle, &WFOriginalCompanionBundle);
    Log(@"[SMSAvailability] experimental iOS15 ACX19 fallback installed");
}
