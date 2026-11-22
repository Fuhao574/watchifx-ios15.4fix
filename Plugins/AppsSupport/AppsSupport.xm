#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include "utils.h"

void WFInstallAppConduitDiagnostics(void);
void WFInstallCompanionRecordDiagnostics(void);
void WFInstallMobileSMSCounterpartFix(void);
void WFInstallMobileSMSCacheMigration(void);

@interface WatchBundle : NSObject
- (BOOL)isApplicableToOSVersion:(id)version error:(id *)error;
@end

%group MessageFixes

%hook ApplicationManager

- (NSDictionary *)_supplementalSystemAppBundleIDMappingForWatchOSSixAndLater {
    Log(@"Original _supplementalSystemAppBundleIDMappingForWatchOSSixAndLater called");
    NSDictionary *result = %orig;
    NSMutableDictionary *mapping = [result mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *sms = @"com.apple.MobileSMS";
    if (!mapping[sms]) {
        [mapping setObject:sms forKey:sms];
        Log(@"Added %@ to supplemental system app mapping", sms);
    } else {
        Log(@"%@ already exists in supplemental system app mapping", sms);
    }
    return mapping;
}

// Confirmed to be called on iOS 15.4 during reunion sync (device trace).
- (NSArray *)_bundleIDsOfLocallyAvailableSystemApps {
    Log(@"Original _bundleIDsOfLocallyAvailableSystemApps called");
    NSArray *result = %orig;
    NSMutableArray *bundleIDs = [result mutableCopy] ?: [NSMutableArray array];
    NSString *sms = @"com.apple.MobileSMS";
    if (![bundleIDs containsObject:sms]) {
        [bundleIDs addObject:sms];
        Log(@"Added %@ to locally available system app list", sms);
    } else {
        Log(@"%@ already exists in locally available system app list", sms);
    }
    return bundleIDs;
}

%end

%end

%group AppsSupport

%hook WatchBundle

- (BOOL)isApplicableToKnownWatchOSVersion {
    return [self isApplicableToOSVersion:@"11.9999" error:nil];
}

- (NSString *)currentOSVersionForValidationWithError:(id *)error {
    return @"11.9999";
}

%end

%end

void InstallAppConduitHook(void) {
    const char *progname = getprogname();
    Class managerClass = objc_lookUpClass("ACXAvailableApplicationManager");
    if (!managerClass) {
        Log(@"ACXAvailableApplicationManager class not found in %s, skipping app conduit hook", progname ?: "<unknown>");
        return;
    }

    Log(@"Installing AppConduit hook in %s (class=%@, supplemental=%@, local-list=%@)",
        progname ?: "<unknown>",
        NSStringFromClass(managerClass),
        [managerClass instancesRespondToSelector:@selector(_supplementalSystemAppBundleIDMappingForWatchOSSixAndLater)] ? @"YES" : @"NO",
        [managerClass instancesRespondToSelector:@selector(_bundleIDsOfLocallyAvailableSystemApps)] ? @"YES" : @"NO");
    %init(MessageFixes, ApplicationManager=managerClass);

    Log(@"Installed appconduit hooks");
}

void InstallAppsSupportHooks(void) {
    Class watchBundleClass = objc_lookUpClass("MIEmbeddedWatchBundle");
    if (!watchBundleClass) {
        Log(@"MIEmbeddedWatchBundle class not found, skipping AppsSupport hooks");
        return;
    }

    %init(AppsSupport, WatchBundle=watchBundleClass);

    Log(@"Installed AppsSupport hooks");
}

%ctor {
    const char *progname = getprogname();
    if (!progname) {
        return;
    }
    Log(@"AppsSupport loaded in process: %s", progname);
    if (is_equal(progname, "appconduitd")) {
        // smsfix1 changed lookup results but did not prevent removal on the
        // test device. Leave the experimental fallback disabled.
        WFInstallMobileSMSCounterpartFix();
        WFInstallCompanionRecordDiagnostics();
        WFInstallMobileSMSCacheMigration();
        WFInstallAppConduitDiagnostics();
    }
    Class appConduitManagerClass = objc_lookUpClass("ACXAvailableApplicationManager");
    if (is_equal(progname, "appconduitd") ||
        is_equal(progname, "com.apple.appconduitd") ||
        appConduitManagerClass != Nil) {
        Log(@"Initializing AppsSupport...");
        InstallAppConduitHook();
    } else if (is_equal(progname, "installd") ||
        is_equal(progname, "MobileInstallationHelperService") ||
        is_equal(progname, "com.apple.MobileInstallationHelperService")) {
        Log(@"Initializing AppsSupport...");
        InstallAppsSupportHooks();
    }
}
