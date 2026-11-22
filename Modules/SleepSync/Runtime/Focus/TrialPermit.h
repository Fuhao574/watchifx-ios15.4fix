#ifndef WF_SLEEP_ONCE3_PERMIT_H
#define WF_SLEEP_ONCE3_PERMIT_H
#include <atomic>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <math.h>
#include <sys/sysctl.h>
#include <CoreFoundation/CoreFoundation.h>
#include "ModuleSession.h"

// Startup-only single-Sleep policy grant. It cannot authorize control upgrades.
// The private directory/grant must exist before the target process starts.
// session-spent is claimed durably before enabling even the first natural send.
// Unix time validates the pregrant; uptime bounds its remaining lifetime after
// claim. Only observed invalid clock samples revoke; unseen rollback is not detected.
// Pre-claim wall-clock rollback is not detected by this grant format.
static dispatch_once_t WFTrialPrepareOnce;
static int WFTrialDirectory = -1;
static pid_t WFTrialCreator;
static NSData *WFTrialGrantBytes;
static struct stat WFTrialGrantStat, WFTrialReceiptStat;
static double WFTrialIssuedUnix, WFTrialDeadlineUnix;
static double WFTrialClaimWall, WFTrialClaimUptime, WFTrialDeadline;
static std::atomic_bool WFTrialRevoked{false};
static std::atomic_bool WFTrialHooksReady{false};

#ifndef WF_TRIAL2_HOST_TEST
static double WFTrialNow(void) {return NSProcessInfo.processInfo.systemUptime;}
static double WFTrialWallNow(void) {return [NSDate date].timeIntervalSince1970;}
static NSString *WFTrialBoot(void) {
    char bytes[128]={};size_t n=sizeof(bytes);
    if (sysctlbyname("kern.bootsessionuuid",bytes,&n,NULL,0) || n<2 || n>sizeof(bytes) || bytes[n-1]) return nil;
    return [[NSString stringWithUTF8String:bytes] uppercaseString];
}
#endif

static BOOL WFTrialSafeFile(const struct stat &s) {
    return S_ISREG(s.st_mode) && s.st_uid==geteuid() && (s.st_mode&07777)==0600 && s.st_nlink==1;
}
static BOOL WFTrialSameFile(const struct stat &a,const struct stat &b) {
    return a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size;
}
static NSData *WFTrialReadGrant(struct stat *st) {
    int fd=openat(WFTrialDirectory,"policy-grant.plist",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0)return nil;
    char bytes[4096];struct stat after;
    BOOL safe=!fstat(fd,st) && WFTrialSafeFile(*st) && st->st_size>0 && (uint64_t)st->st_size<=sizeof(bytes);
    ssize_t n=safe ? read(fd,bytes,(size_t)st->st_size) : -1;
    safe=safe && n==st->st_size && !fstat(fd,&after) && WFTrialSafeFile(after) && WFTrialSameFile(*st,after);
    if(close(fd))safe=NO;
    return safe ? [NSData dataWithBytes:bytes length:(NSUInteger)n] : nil;
}
static void WFTrialPrepare(void) {
    dispatch_once(&WFTrialPrepareOnce, ^{
        WFTrialCreator=getpid();
        const char *path=WFModuleDirectory("focus");
        if(path)WFTrialDirectory=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(WFTrialDirectory<0)return;
        struct stat directory;
        if(fstat(WFTrialDirectory,&directory) || !S_ISDIR(directory.st_mode) ||
            directory.st_uid!=geteuid() || (directory.st_mode&07777)!=0700)return;
        NSData *bytes=WFTrialReadGrant(&WFTrialGrantStat);
        id value=bytes ? [NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:nil] : nil;
        if(![value isKindOfClass:[NSDictionary class]])return;
        NSDictionary *grant=value;
        if(grant.count!=5 || ![grant[@"schema"] isEqual:@"sleep-module1-policy-v1"] ||
            ![grant[@"scope"] isEqual:@"one-additive-sleep-update-no-control"] ||
            ![grant[@"bootUUID"] isKindOfClass:[NSString class]] ||
            ![grant[@"issuedUnix"] isKindOfClass:[NSNumber class]] ||
            ![grant[@"deadlineUnix"] isKindOfClass:[NSNumber class]] ||
            CFGetTypeID((__bridge CFTypeRef)grant[@"issuedUnix"])==CFBooleanGetTypeID() ||
            CFGetTypeID((__bridge CFTypeRef)grant[@"deadlineUnix"])==CFBooleanGetTypeID())return;
        NSString *boot=WFTrialBoot();
        double issued=[grant[@"issuedUnix"] doubleValue],deadline=[grant[@"deadlineUnix"] doubleValue];
        // Sample uptime first so sampling delay cannot extend the monotonic lease.
        double claimUptime=WFTrialNow(),now=WFTrialWallNow();
        if(!boot || ![grant[@"bootUUID"] isEqual:boot] || !isfinite(issued) || !isfinite(deadline) ||
            !isfinite(now) || !isfinite(claimUptime) || claimUptime<0 || issued<0 || issued>now ||
            deadline<=now || deadline<=issued || deadline-issued>180.0)return;
        double monotonicDeadline=claimUptime+(deadline-now);
        if(!isfinite(monotonicDeadline) || monotonicDeadline<=claimUptime)return;
        int fd=openat(WFTrialDirectory,"session-spent",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
        if(fd<0)return;
        // Failures consume the session too; never unlink a receipt or retry.
        const char receipt[]="WF-SLEEP-ONCE3-STARTUP-SESSION-CONSUMED\n";
        BOOL durable=write(fd,receipt,sizeof(receipt)-1)==sizeof(receipt)-1 && fsync(fd)==0;
        if(fstat(fd,&WFTrialReceiptStat) || !WFTrialSafeFile(WFTrialReceiptStat))durable=NO;
        if(close(fd))durable=NO;
        if(fsync(WFTrialDirectory))durable=NO;
        if(!durable)return;
        WFTrialGrantBytes=bytes;
        WFTrialIssuedUnix=issued;
        WFTrialDeadlineUnix=deadline;
        WFTrialClaimWall=now;
        WFTrialClaimUptime=claimUptime;
        WFTrialDeadline=monotonicDeadline;
    });
}
static BOOL WFTrialLeaseValid(void) {
    // Also safe if a natural send precedes this translation unit's constructor.
    WFTrialPrepare();
    if(WFTrialCreator!=getpid() || !WFTrialGrantBytes || WFTrialRevoked.load() || !WFModuleSessionActive())return NO;
    struct stat current,receipt,directory;
    NSData *bytes=WFTrialReadGrant(&current);
    double now=WFTrialNow(),wall=WFTrialWallNow();
    BOOL valid=isfinite(now) && isfinite(wall) &&
        wall>=WFTrialIssuedUnix && wall>=WFTrialClaimWall && wall<WFTrialDeadlineUnix &&
        now>=WFTrialClaimUptime && now<WFTrialDeadline && bytes &&
        [bytes isEqualToData:WFTrialGrantBytes] && WFTrialSameFile(current,WFTrialGrantStat) &&
        !fstat(WFTrialDirectory,&directory) && S_ISDIR(directory.st_mode) &&
        directory.st_uid==geteuid() && (directory.st_mode&07777)==0700 &&
        !fstatat(WFTrialDirectory,"session-spent",&receipt,AT_SYMLINK_NOFOLLOW) &&
        WFTrialSafeFile(receipt) && WFTrialSameFile(receipt,WFTrialReceiptStat);
    if(!valid)WFTrialRevoked.store(true); // No rearm after observed revoke/expiry.
    return valid;
}
BOOL WFTrialEnabled(void) {return WFTrialHooksReady.load() && WFTrialLeaseValid();}
void WFTrialInitialize(void) {
    WFTrialPrepare();
    WFLog(__FILE__,@"[FocusCompatProbe] SLEEPMODULE1 startup session claimed=%@ pid=%d issuedUnix=%.3f deadlineUnix=%.3f claimWall=%.3f claimUptime=%.3f deadlineUptime=%.3f policy=EXPLICITLY_ARMED",
        WFTrialGrantBytes ? @"YES":@"NO",getpid(),WFTrialIssuedUnix,WFTrialDeadlineUnix,WFTrialClaimWall,WFTrialClaimUptime,WFTrialDeadline);
}
void WFTrialSetHooksReady(BOOL ready) {
    if(!ready) {WFTrialRevoked.store(true);WFTrialHooksReady.store(false);return;}
    if(WFTrialLeaseValid())WFTrialHooksReady.store(true);
}
BOOL WFTrialPolicyReady(void) {return WFTrialEnabled();}
BOOL WFTrialClaimReceipt(NSString *name,BOOL policy) {
    if(!policy || ![name isEqual:@"policy-spent"] || !WFTrialEnabled())return NO;
    int fd=openat(WFTrialDirectory,"policy-spent",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return NO;
    const char receipt[]="WF-SLEEP-ONCE3-POLICY-CONSUMED\n";
    BOOL durable=write(fd,receipt,sizeof(receipt)-1)==sizeof(receipt)-1 && fsync(fd)==0;
    if(close(fd))durable=NO;
    if(fsync(WFTrialDirectory))durable=NO;
    return durable && WFTrialEnabled();
}
#endif
