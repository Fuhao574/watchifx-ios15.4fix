// Policy-only one-Sleep trial with bounded private protocol logs.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <sys/sysctl.h>
#include <syslog.h>
#include <stdio.h>
#include <roothide.h>
#include "BoundedLog.h"
#include "utils.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <math.h>
#include "TrialPermit.h"

static WFSleepDiagnostic::BoundedLog output;
static void OpenDiagnostic(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // The directory must be explicitly prepared for this experiment. Do not
        // create it, alter its permissions, overwrite logs, or fall back to /tmp.
        const char *resolved=WFModuleDirectory("focus");
        bool opened=resolved && output.Open(resolved,501);
        syslog(LOG_NOTICE,"[WFSleepModule1] diagnostic-open=%d pid=%d",opened,getpid());
        if(opened) output.Append("[WFSleepModule1] diagnostic-open=1 policy-only=1 readonlyBuild=0 controlUpgrade=NO");
    });
}
void WFLog(const char *file, NSString *format, ...) {
    (void)file;
    // Only reviewed protocol diagnostics. Never serialize arbitrary objects.
    if (![format hasPrefix:@"[FocusCompatProbe]"] && ![format hasPrefix:@"[FocusCompat]"]) return;
    va_list args; va_start(args,format);
    NSString *message=[[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    syslog(LOG_NOTICE,"[WFSleepModule1] %s",message.UTF8String ?: "<invalid>");
    OpenDiagnostic();
    NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
    NSString *timed = [NSString stringWithFormat:@"uptime=%.3f %@", uptime, message];
    output.Append(timed.UTF8String);
}
id CopyObjectIvarValueByName(id object,const char *name,Class expectedClass) {
    if(!object || !name) return nil;
    Ivar ivar=class_getInstanceVariable(object_getClass(object),name);
    if(!ivar) return nil;
    id value=object_getIvar(object,ivar);
    return value && (!expectedClass || [value isKindOfClass:expectedClass]) ? value : nil;
}
static NSInteger version[3];
static void ReadVersion(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char text[32]={}; size_t size=sizeof(text);
        if(sysctlbyname("kern.osproductversion",text,&size,NULL,0)) return;
        int major=0,minor=0,patch=0;
        if(sscanf(text,"%d.%d.%d",&major,&minor,&patch)<2) return;
        version[0]=major;version[1]=minor;version[2]=patch;
    });
}
NSInteger IOSMajorVersion(void) {ReadVersion();return version[0];}
NSInteger IOSMinorVersion(void) {ReadVersion();return version[1];}
NSInteger IOSPatchVersion(void) {ReadVersion();return version[2];}

// Policy readiness is defined by the startup-only TrialPermit header.

// Initialization is explicitly ordered before Focus hook installation.
