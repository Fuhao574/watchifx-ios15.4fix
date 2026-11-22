#ifndef WF_SLEEP_MODULE_SESSION_H
#define WF_SLEEP_MODULE_SESSION_H
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <roothide.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <math.h>

// App-owned session selector, never a policy or system database. Each injected
// process captures one selector at startup and cannot follow a later session.
static NSString *WFModuleRoot(void) {
    const char *path=jbroot("/var/mobile/Library/Application Support/WatchFix/SleepSync");
    return path ? [NSString stringWithUTF8String:path]:nil;
}
static NSString *WFModuleBoot(void) {
    char b[128]={};size_t n=sizeof(b);
    if(sysctlbyname("kern.bootsessionuuid",b,&n,NULL,0) || n<2 || n>sizeof(b) || b[n-1])return nil;
    return [[NSString stringWithUTF8String:b] uppercaseString];
}
static BOOL WFModulePrivate(struct stat s,BOOL directory) {
    return s.st_uid==501 && (s.st_mode&07777)==(directory?0700:0600) &&
        (directory?S_ISDIR(s.st_mode):(S_ISREG(s.st_mode)&&s.st_nlink==1));
}
static NSData *WFModuleSelector(NSString *root) {
    int fd=open([[root stringByAppendingPathComponent:@"current-session.plist"] fileSystemRepresentation],O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0)return nil;
    struct stat s;char bytes[4096];ssize_t n=-1;
    if(!fstat(fd,&s)&&WFModulePrivate(s,NO)&&s.st_size>0&&s.st_size<=4096)n=read(fd,bytes,s.st_size);
    close(fd);
    return n>0&&n==s.st_size?[NSData dataWithBytes:bytes length:n]:nil;
}
static NSData *WFModuleCapturedSelector;
static int WFModulePinnedDirectory=-1;
static dev_t WFModulePinnedDev;
static ino_t WFModulePinnedInode;
static NSString *WFModuleSessionDirectory(void) {
    static dispatch_once_t once;static NSString *directory;
    dispatch_once(&once,^{
        NSString *root=WFModuleRoot();struct stat st;
        if(!root||lstat(root.fileSystemRepresentation,&st)||!WFModulePrivate(st,YES))return;
        NSData *bytes=WFModuleSelector(root);
        id value=bytes?[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:nil]:nil;
        if(![value isKindOfClass:[NSDictionary class]]||[value count]!=5||![value[@"schema"] isEqual:@1]||
           ![value[@"sessionID"] isKindOfClass:[NSString class]]||![value[@"bootUUID"] isEqual:WFModuleBoot()]||
           ![value[@"startedAt"] isKindOfClass:[NSNumber class]]||![value[@"deadline"] isKindOfClass:[NSNumber class]])return;
        NSString *identifier=value[@"sessionID"];
        if(![[[NSUUID alloc] initWithUUIDString:identifier].UUIDString isEqual:identifier])return;
        double start=[value[@"startedAt"] doubleValue],end=[value[@"deadline"] doubleValue],now=NSDate.date.timeIntervalSince1970;
        if(!isfinite(start)||!isfinite(end)||start>now||end<=now||end-start>420||end<=start)return;
        NSString *sessions=[root stringByAppendingPathComponent:@"Sessions"];
        if(lstat(sessions.fileSystemRepresentation,&st)||!WFModulePrivate(st,YES))return;
        NSString *candidate=[sessions stringByAppendingPathComponent:identifier];
        if(lstat(candidate.fileSystemRepresentation,&st)||!WFModulePrivate(st,YES))return;
        int pinned=open(candidate.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        struct stat verified;
        if(pinned<0)return;
        if(fstat(pinned,&verified)||!WFModulePrivate(verified,YES)||verified.st_ino!=st.st_ino||verified.st_dev!=st.st_dev) {close(pinned);return;}
        WFModulePinnedDirectory=pinned;WFModulePinnedDev=st.st_dev;WFModulePinnedInode=st.st_ino;
        directory=candidate;WFModuleCapturedSelector=bytes;
    });
    return directory;
}
static BOOL WFModuleSessionActive(void) {
    static BOOL invalid;static NSLock *lock;static dispatch_once_t once;
    dispatch_once(&once,^{lock=[NSLock new];});
    [lock lock];@try {
        if(invalid)return NO;
        NSString *directory=WFModuleSessionDirectory();NSString *root=WFModuleRoot();
        NSData *current=WFModuleSelector(root);
        if(!directory||!current||![current isEqual:WFModuleCapturedSelector]) {invalid=YES;return NO;}
        id value=[NSPropertyListSerialization propertyListWithData:current options:NSPropertyListImmutable format:NULL error:nil];
        double now=NSDate.date.timeIntervalSince1970;
        struct stat st;
        if(lstat(directory.fileSystemRepresentation,&st)||!WFModulePrivate(st,YES)||
            st.st_dev!=WFModulePinnedDev||st.st_ino!=WFModulePinnedInode) {invalid=YES;return NO;}
        NSString *sessions=directory.stringByDeletingLastPathComponent;
        if(lstat(sessions.fileSystemRepresentation,&st)||!WFModulePrivate(st,YES)||
           lstat(root.fileSystemRepresentation,&st)||!WFModulePrivate(st,YES)) {invalid=YES;return NO;}
        if(![value isKindOfClass:[NSDictionary class]]||now<[value[@"startedAt"] doubleValue]||
           now>=[value[@"deadline"] doubleValue]||
           !lstat([[directory stringByAppendingPathComponent:@"cancel-requested"] fileSystemRepresentation],&st)||
           !lstat([[directory stringByAppendingPathComponent:@"closed"] fileSystemRepresentation],&st)) {invalid=YES;return NO;}
        return YES;
    } @finally {[lock unlock];}
}
static const char *WFModuleDirectory(const char *child) {
    if(strcmp(child,"focus")&&strcmp(child,"identity"))return NULL;
    NSString *directory=WFModuleSessionDirectory();if(!directory)return NULL;
    NSString *path=[directory stringByAppendingPathComponent:[NSString stringWithUTF8String:child]];
    struct stat s;if(lstat(path.fileSystemRepresentation,&s)||!WFModulePrivate(s,YES)||!WFModuleSessionActive())return NULL;
    // Intern one immutable path per process; callers never free these strings.
    return strdup(path.fileSystemRepresentation);
}
static BOOL WFModuleIdentityEnabled(void) {
    if(!WFModuleSessionActive())return NO;
    NSString *directory=WFModuleSessionDirectory();struct stat st;
    if(fstatat(WFModulePinnedDirectory,"identity-enabled",&st,AT_SYMLINK_NOFOLLOW)||
       !S_ISREG(st.st_mode)||st.st_nlink!=1||st.st_uid!=0||(st.st_mode&07777)!=0600)return NO;
    // Claim once per SESSION before any candidate attempt, not once per daemon.
    int fd=openat(WFModulePinnedDirectory,"identity-spent",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return NO;
    const char text[]="IDENTITY-CANDIDATE-ATTEMPT-CONSUMED\n";
    BOOL ok=write(fd,text,sizeof(text)-1)==sizeof(text)-1&&fsync(fd)==0;close(fd);
    int parent=open(directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(parent<0)return NO;if(fsync(parent))ok=NO;close(parent);
    return ok&&WFModuleSessionActive();
}
#endif
