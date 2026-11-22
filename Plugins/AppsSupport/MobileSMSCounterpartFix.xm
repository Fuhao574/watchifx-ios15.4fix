#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <substrate.h>
#include <stdlib.h>
#include <string.h>
#include "utils.h"

// Experimental, narrowly scoped source-record repair. On the test device
// (iOS 15.4), MobileSMS exists but its LS counterpartIdentifiers is [], and
// the watcher's corresponding cached association is nil. The watch removes
// Messages for lack of its phone counterpart. Repair the getter used by the
// normal rescan/serialization flow; never write a plist, fabricate sequence
// numbers, suppress removals, or override another application's association.
static IMP WFOriginalMobileSMSCounterparts;

static BOOL WFObjectGetterABI(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = type && strcmp(type, "@") == 0;
    free(type);
    return valid;
}

static id WFMobileSMSCounterparts(id self, SEL selector) {
    id original = ((id (*)(id, SEL))WFOriginalMobileSMSCounterparts)(self, selector);
    // Preserve all existing nonempty associations and unexpected result types.
    BOOL empty = original == nil ||
        ([original isKindOfClass:[NSArray class]] && [original count] == 0);
    if (!empty) return original;

    SEL bundleSelector = sel_registerName("bundleIdentifier");
    Method method = class_getInstanceMethod(object_getClass(self), bundleSelector);
    if (!WFObjectGetterABI(method)) return original;
    id bundleID = ((id (*)(id, SEL))[self methodForSelector:bundleSelector])(self, bundleSelector);
    if (![bundleID isKindOfClass:[NSString class]] ||
        ![bundleID isEqualToString:@"com.apple.MobileSMS"]) return original;

    Log(@"[SMSCounterpart] iOS15.4 MobileSMS empty LS association -> [MobileSMS]");
    return @[@"com.apple.MobileSMS"];
}

void WFInstallMobileSMSCounterpartFix(void) {
    // NSProcessInfo is spoofed by PairingCompatibility. Check the real OS and
    // host executable independently so this never changes global LS behavior.
    const char *program = getprogname();
    if (!program || strcmp(program, "appconduitd") != 0 ||
        IOSMajorVersion() != 15 || IOSMinorVersion() != 4) {
        Log(@"[SMSCounterpart] skipped: requires real iOS15.4 appconduitd");
        return;
    }
    Class cls = objc_lookUpClass("LSApplicationRecord");
    SEL selector = sel_registerName("counterpartIdentifiers");
    if (!WFObjectGetterABI(class_getInstanceMethod(cls, selector)) ||
        !WFObjectGetterABI(class_getInstanceMethod(cls, sel_registerName("bundleIdentifier")))) {
        Log(@"[SMSCounterpart] skipped: LS getter missing or ABI mismatch");
        return;
    }
    MSHookMessageEx(cls, selector, (IMP)WFMobileSMSCounterparts, &WFOriginalMobileSMSCounterparts);
    Log(@"[SMSCounterpart] experimental empty-association repair installed");
}
