// Runtime entry for the authorized install layer.
//
// Loaded into healthd only (see WatchFix_HealthSupport.plist). Loading is not
// activation: the constructor returns without touching anything unless both the
// host check and the projection marker pass. Acceptance additionally needs its
// own marker, so turning new stage reception off never removes the projection
// that already-stored stage values depend on.
//
// Nothing here installs, restarts, copies, or reads health data.
#import <Foundation/Foundation.h>
#import <os/log.h>

#include <mach-o/dyld.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>

#include "EnableMarker.h"
#include "Exact154Targets.hpp"
#include "HealthSupportBootstrap.hpp"
#include "RuntimeSignal.h"

// healthd's sandbox decides which of these it may read (15.4: it sees the first
// directory but its open() is refused). The runtime tries them in order and
// uses the first one whose projection marker it can actually read. Paths are
// what healthd itself sees: on a rootless jailbreak the real tree may sit
// behind /rootfs for the shell but not for a system daemon.
static NSArray<NSString *> *WFHSMarkerDirectories(void) {
    static NSArray<NSString *> *directories;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        directories = @[
            @"/var/mobile/Library/WatchFixHealthSupport",
            @"/var/mobile/Library/Preferences/WatchFixHealthSupport",
            @"/var/mobile/Library/Caches/WatchFixHealthSupport",
            @"/usr/local/lib/watchfix-health-support",
            @"/var/jb/usr/lib/watchfix-health-support",
            @"/var/db/watchfix-health-support",
            @"/var/tmp/watchfix-health-support",
        ];
    });
    return directories;
}
static const char *const WFHSHealthDaemonPath =
    "/System/Library/Frameworks/HealthKit.framework/healthd";
static const char *const WFHSRootFsPrefix = "/rootfs";

static os_log_t WFHSLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("cn.fkj233.watchfix.healthsupport", "runtime");
    });
    return log;
}

static NSString *WFHSCurrentOSBuild(void) {
    char value[64] = {0};
    size_t size = sizeof(value) - 1;
    if (sysctlbyname("kern.osversion", value, &size, NULL, 0) != 0) {
        return nil;
    }
    value[sizeof(value) - 1] = '\0';
    return [NSString stringWithUTF8String:value];
}

// Exact host identity, not a suffix match: another executable called healthd
// must not activate this layer.
static NSString *WFHSCurrentExecutablePath(void) {
    uint32_t size = 4096;
    char buffer[4096] = {0};
    if (_NSGetExecutablePath(buffer, &size) != 0) {
        return @"?";
    }
    buffer[sizeof(buffer) - 1] = '\0';
    return [NSString stringWithUTF8String:buffer];
}

static BOOL WFHSCurrentExecutableIsHealthd(NSString *path) {
    if (!path) {
        return NO;
    }
    const char *name = path.UTF8String;
    if (strcmp(name, WFHSHealthDaemonPath) == 0) {
        return YES;
    }
    // Rootless bootstrap may report the real path behind the rootfs symlink;
    // only that exact prefix is stripped, nothing is suffix-matched.
    const size_t prefix = strlen(WFHSRootFsPrefix);
    return strncmp(name, WFHSRootFsPrefix, prefix) == 0 &&
           strcmp(name + prefix, WFHSHealthDaemonPath) == 0;
}

// Status codes carried in the status line. Codes only ever increase, so the
// last line found in healthd's memory is the final state of this load.
enum : int {
    WFHSSignalRejectedHost = 1,        // loaded, but build/executable check failed
    WFHSSignalMarkerAbsent = 2,        // correct host, projection marker missing
    WFHSSignalMarkerNotRegular = 3,    // projection marker: not a regular single-link file
    WFHSSignalMarkerWrongOwner = 4,    // projection marker: owner is not the healthd user
    WFHSSignalMarkerWrongMode = 5,     // projection marker: mode is not 0600
    WFHSSignalMarkerWrongSize = 6,     // projection marker: empty or too large
    WFHSSignalMarkerWrongContent = 7,  // projection marker: text/build mismatch
    WFHSSignalMarkerReadFailed = 8,    // projection marker: open/read failed
    WFHSSignalTargetsRejected = 9,     // classes/methods did not match this firmware
    WFHSSignalReadyWithAccept = 10,    // projection + acceptance installed and verified
    WFHSSignalReadyProjectionOnly = 11, // projection installed and verified, no accept marker
    WFHSSignalInstalledNotReady = 12,   // something installed, verification did not pass
    WFHSSignalNothingInstalled = 13,   // no hook installed, native behaviour unchanged
    WFHSSignalException = 14,          // constructor raised
};

// Marker states map 1:1 onto WFHSSignalMarker* + 1; WFHSEnableMarkerValid never
// reaches this helper because it means "continue".
static int WFHSSignalForMarker(WFHSEnableMarkerState state) {
    return state >= WFHSEnableMarkerNotRegular && state <= WFHSEnableMarkerReadFailed
        ? (int)state + 1
        : WFHSSignalMarkerAbsent;
}

static void WFHSReport(int signal, NSUInteger directory, NSString *build, int host, NSString *path,
                       int projection, int acceptance, int ready, int projectionStatus,
                       int acceptanceStatus, unsigned failures)
{
    NSString *line = [NSString stringWithFormat:
        @"WFHS-STATUS-V1 signal=%d dir=%lu build=%@ host=%d exe=%@ projection=%d accept=%d "
         "ready=%d projectionStatus=%d acceptStatus=%d failures=%u pid=%d",
        signal, (unsigned long)directory, build.length ? build : @"?", host, path, projection,
        acceptance, ready, projectionStatus, acceptanceStatus, failures, getpid()];
    // Every file this layer could write is refused by the healthd sandbox and
    // the device has no log reader, so the in-memory line (read back through
    // the task port) is the only status channel that works on this device.
    os_log(WFHSLog(), "%{public}@", line);
    WFHSPublishRuntimeSignal(line);
}

__attribute__((constructor)) static void WFHSRuntimeLoad(void)
{
    @autoreleasepool {
        @try {
            NSString *build = WFHSCurrentOSBuild();
            NSString *path = WFHSCurrentExecutablePath();
            const BOOL host = WFHSCurrentExecutableIsHealthd(path);
            // First line separates "never injected" from "rejected by the host
            // check": no line at all means the constructor never ran.
            WFHSReport(WFHSSignalRejectedHost, 0, build, host ? 1 : 0, path, 0, 0, 0, -1, -1, 0);
            if (!build.length || !host) {
                return;
            }
            // "Absent" and "read failed" mean "not here / not readable", so the
            // next directory is tried. Any other state is a real misconfiguration
            // (wrong owner, mode, size or content) and stops the search.
            WFHSEnableMarkerState projection = WFHSEnableMarkerAbsent;
            WFHSEnableMarkerState firstUnreadable = WFHSEnableMarkerAbsent;
            // 1-based in the status line; 0 means "before the directory search".
            NSUInteger directory = 0;
            NSString *markerDirectory = nil;
            for (NSUInteger index = 0; index < WFHSMarkerDirectories().count; index++) {
                markerDirectory = WFHSMarkerDirectories()[index];
                directory = index;
                projection = WFHSReadEnableMarker(
                    [markerDirectory stringByAppendingPathComponent:@"projection"], build);
                if (projection == WFHSEnableMarkerValid ||
                    (projection != WFHSEnableMarkerAbsent &&
                     projection != WFHSEnableMarkerReadFailed)) {
                    break;
                }
                if (projection == WFHSEnableMarkerReadFailed && firstUnreadable == WFHSEnableMarkerAbsent) {
                    firstUnreadable = projection;
                }
            }
            if (projection != WFHSEnableMarkerValid) {
                if (projection == WFHSEnableMarkerAbsent) {
                    projection = firstUnreadable;
                }
                WFHSReport(WFHSSignalForMarker(projection), directory + 1, build, 1, path, 0, 0, 0, -1, -1, 0);
                return;
            }
            const WFHSEnableMarkerState acceptance = WFHSReadEnableMarker(
                [markerDirectory stringByAppendingPathComponent:@"accept"], build);

            WFHSExact154Targets targets = {};
            NSMutableArray<NSString *> *failures = [NSMutableArray array];
            if (!WFHSResolveExact154Targets(&targets, failures)) {
                WFHSReport(WFHSSignalTargetsRejected, directory + 1, build, 1, path, 1,
                           acceptance == WFHSEnableMarkerValid ? 1 : 0, 0, -1, -1,
                           (unsigned)failures.count);
                return;
            }
            WFHSActivationGate *gate =
                [WFHSActivationGate gateWithName:@"healthsupport.runtime"];
            WFHSHealthSupportSetup *setup = WFHSSetupHealthSupport(
                targets.classes,
                acceptance == WFHSEnableMarkerValid ? targets.category_type : Nil,
                gate, 100000, 100000);
            const BOOL installed = setup.projectionSlot.installed || setup.acceptanceSlot.installed;
            WFHSReport(setup.ready ? (acceptance == WFHSEnableMarkerValid
                                          ? WFHSSignalReadyWithAccept
                                          : WFHSSignalReadyProjectionOnly)
                       : installed ? WFHSSignalInstalledNotReady
                                   : WFHSSignalNothingInstalled,
                       directory + 1, build, 1, path, (int)setup.projectionSlot.installed,
                       (int)setup.acceptanceSlot.installed, (int)setup.ready,
                       (int)setup.projectionStatus, (int)setup.acceptanceStatus, 0);
        } @catch (NSException *candidateException) {
            (void)candidateException;
            WFHSPublishRuntimeSignal(
                [NSString stringWithFormat:@"WFHS-STATUS-V1 signal=%d exception=%@ pid=%d",
                 WFHSSignalException, candidateException.description, getpid()]);
        }
    }
}
