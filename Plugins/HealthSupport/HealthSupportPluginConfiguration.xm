#import <Foundation/Foundation.h>
#import <sys/sysctl.h>

#import "PluginBridge.h"
#import "PluginConfig.h"

// WatchFix installs this plugin's dylib into healthd like any other module.
// What the dylib does once loaded is decided by two marker files it reads:
//
//   projection   installs the day-summary replacement
//   accept       lets healthd store sleep stage values 3, 4 and 5
//
// The list treats the plugin as enabled while `accept` exists. Removing the
// plugin takes only `accept` away and restarts healthd, so new stages are
// rejected again. The dylib and `projection` stay: once stage values are
// stored, the native day-summary code would run into them and raise, so the
// replacement has to remain in place as a guard. The row then shows as not
// installed, and installing again brings `accept` back.
//
// healthd's sandbox let it read a marker from exactly one place on 15.4.
static NSString *const kMarkerDirectory = @"/var/tmp/watchfix-health-support";
static NSString *const kProjectionMarker = @"projection";
static NSString *const kAcceptMarker = @"accept";
static NSString *const kMarkerPrefix = @"WFHS-ENABLE-V1";
static NSString *const kHealthdService = @"system/com.apple.healthd";

static NSString *MarkerPath(NSString *name) {
    return [kMarkerDirectory stringByAppendingPathComponent:name];
}

// Same domain as the bridge's own errors. Built here because the shared
// internal header also carries helpers this file does not use.
static NSError *ProviderError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"cn.fkj233.watchfix.app"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

static BOOL MarkerExists(NSString *name) {
    BOOL isDirectory = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:MarkerPath(name) isDirectory:&isDirectory] && !isDirectory;
}

static BOOL WriteMarker(NSString *name, NSError **error) {
    char build[64] = {0};
    size_t length = sizeof(build) - 1;
    if (sysctlbyname("kern.osversion", build, &length, NULL, 0) != 0) {
        if (error) {
            *error = ProviderError(60, @"Unable to read the system build number");
        }
        return NO;
    }
    NSString *content = [NSString stringWithFormat:@"%@ %s\n", kMarkerPrefix, build];
    // The runtime only honours a marker owned by healthd's own user, mode 0600.
    return [WFPluginBridge installFileAtPath:MarkerPath(name) content:content owner:@"mobile:mobile" mode:@0600 error:error];
}

static NSString *StatusString(WFPluginConfigurationContext *context, NSString *key, NSString *fallback) {
    return [context localizedStringForKey:[NSString stringWithFormat:@"plugin.HealthSupport.%@", key] fallback:fallback];
}

@interface HealthSupportPluginConfiguration : NSObject <WFPluginConfigurationProvider>
@end

@implementation HealthSupportPluginConfiguration

+ (BOOL)pluginIsEnabledWithIdentifier:(NSString *)pluginIdentifier pluginInfo:(NSDictionary<NSString *, id> *)pluginInfo {
    (void)pluginIdentifier;
    (void)pluginInfo;
    return MarkerExists(kAcceptMarker);
}

+ (BOOL)installPluginWithContext:(WFPluginConfigurationContext *)context error:(NSError **)error {
    // Markers first: the loader picks the dylib up as soon as the filter exists.
    if (!WriteMarker(kProjectionMarker, error) || !WriteMarker(kAcceptMarker, error)) {
        return NO;
    }
    if (![context installUsingDefaultImplementation:error]) {
        return NO;
    }
    return [WFPluginBridge restartLaunchdServiceNamed:kHealthdService error:error];
}

+ (BOOL)removePluginWithContext:(WFPluginConfigurationContext *)context error:(NSError **)error {
    BOOL wasAccepting = MarkerExists(kAcceptMarker);
    if (wasAccepting && ![WFPluginBridge removeFileAtPath:MarkerPath(kAcceptMarker) error:error]) {
        return NO;
    }
    if (!MarkerExists(kProjectionMarker)) {
        // The runtime never activated, so no stage value can be stored and
        // removing everything is safe.
        return [context removeUsingDefaultImplementation:error];
    }
    return wasAccepting ? [WFPluginBridge restartLaunchdServiceNamed:kHealthdService error:error] : YES;
}

+ (NSDictionary<NSString *, id> *)configurationPageWithContext:(WFPluginConfigurationContext *)context {
    NSString *acceptance = StatusString(context, MarkerExists(kAcceptMarker) ? @"status.accept.on" : @"status.accept.off", @"");
    NSString *guard = StatusString(context, MarkerExists(kProjectionMarker) ? @"status.projection.on" : @"status.projection.off", @"");
    return @{
        @"title": context.pluginTitle,
        @"sections": @[
            @{
                @"title": StatusString(context, @"status.accept.title", @""),
                @"footer": acceptance,
                @"controls": @[],
            },
            @{
                @"title": StatusString(context, @"status.projection.title", @""),
                @"footer": guard,
                @"controls": @[],
            },
        ],
    };
}

@end
