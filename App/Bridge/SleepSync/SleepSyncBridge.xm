#import "SleepSyncBridge.h"
#import <roothide.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

extern "C" char **environ;
extern "C" int posix_spawnattr_set_persona_np(const posix_spawnattr_t *,uid_t,uint32_t);
extern "C" int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *,uid_t);
extern "C" int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *,gid_t);
static NSString *const WFSSRoot=@"/var/mobile/Library/Application Support/WatchFix/SleepSync";
static NSString *const WFSSRuntime=@"/Applications/WatchFix.app/SleepSyncRuntime";
static NSString *SSPath(NSString *path) {const char *p=jbroot(path.fileSystemRepresentation);return p?[NSString stringWithUTF8String:p]:path;}
static BOOL SSErr(NSError **error,NSInteger code,NSString *message) {
    if(error)*error=[NSError errorWithDomain:@"cn.fkj233.watchfix.sleepsync" code:code userInfo:@{NSLocalizedDescriptionKey:message}];return NO;
}
static BOOL SSSafeDirectory(NSString *path,NSError **error) {
    struct stat s;
    if(lstat(path.fileSystemRepresentation,&s)) {
        if(errno!=ENOENT||mkdir(path.fileSystemRepresentation,0700))return SSErr(error,1,@"无法准备同步会话目录。");
        if(lstat(path.fileSystemRepresentation,&s))return NO;
    }
    return S_ISDIR(s.st_mode)&&s.st_uid==geteuid()&&(s.st_mode&07777)==0700 ? YES:SSErr(error,2,@"同步目录权限异常，已停止。");
}
static BOOL SSRootReady(NSError **error) {
    NSString *support=SSPath(@"/var/mobile/Library/Application Support");
    NSString *watchfix=[support stringByAppendingPathComponent:@"WatchFix"];
    // Application Support is shared; never chmod or take ownership of it.
    struct stat s;if(lstat(support.fileSystemRepresentation,&s)||!S_ISDIR(s.st_mode))return SSErr(error,3,@"Application Support 不可用。");
    return SSSafeDirectory(watchfix,error)&&SSSafeDirectory(SSPath(WFSSRoot),error)&&
        SSSafeDirectory([SSPath(WFSSRoot) stringByAppendingPathComponent:@"Sessions"],error);
}
static NSDictionary *SSRead(NSString *path) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0)return nil;struct stat s;char b[16384];ssize_t n=-1;
    if(!fstat(fd,&s)&&S_ISREG(s.st_mode)&&s.st_nlink==1&&s.st_size>0&&s.st_size<=sizeof(b))n=read(fd,b,s.st_size);
    close(fd);if(n<=0||n!=s.st_size)return nil;
    id v=[NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:b length:n] options:NSPropertyListImmutable format:NULL error:nil];
    return [v isKindOfClass:[NSDictionary class]]?v:nil;
}
static BOOL SSWrite(NSString *path,NSDictionary *value,mode_t mode,NSError **error) {
    NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListXMLFormat_v1_0 options:0 error:error];if(!bytes)return NO;
    NSString *tmp=[path stringByAppendingFormat:@".%@.new",NSUUID.UUID.UUIDString];
    int fd=open(tmp.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,mode);
    if(fd<0)return SSErr(error,4,@"无法持久保存会话状态。");
    BOOL ok=write(fd,bytes.bytes,bytes.length)==(ssize_t)bytes.length&&fsync(fd)==0;
    if(close(fd))ok=NO;
    if(!ok)return SSErr(error,5,@"会话状态落盘失败，保留失败痕迹。");
    if(rename(tmp.fileSystemRepresentation,path.fileSystemRepresentation))return SSErr(error,6,@"无法发布会话状态。");
    int parent=open(path.stringByDeletingLastPathComponent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(parent<0)return NO;ok=fsync(parent)==0;close(parent);return ok;
}
static BOOL SSWriteTime(NSString *path,long long value,NSError **error) {
    NSData *bytes=[[NSString stringWithFormat:@"%lld\n",value] dataUsingEncoding:NSASCIIStringEncoding];
    int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return SSErr(error,18,@"无法固定本次同步的截止时间。");
    BOOL ok=write(fd,bytes.bytes,bytes.length)==(ssize_t)bytes.length&&fsync(fd)==0;
    if(close(fd))ok=NO;
    return ok?YES:SSErr(error,19,@"本次同步时间记录未完成，已停止。");
}
static NSString *SSCurrentID(void) {
    id value=SSRead([SSPath(WFSSRoot) stringByAppendingPathComponent:@"current-session.plist"])[@"sessionID"];
    if(![value isKindOfClass:[NSString class]])return nil;
    return [[[[NSUUID alloc] initWithUUIDString:value] UUIDString] isEqual:value]?value:nil;
}
static BOOL SSHasSessionEvidence(void) {
    NSString *root=SSPath(WFSSRoot);struct stat s;
    if(!lstat([[root stringByAppendingPathComponent:@"current-session.plist"] fileSystemRepresentation],&s))return YES;
    NSArray *items=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:[root stringByAppendingPathComponent:@"Sessions"] error:nil];
    return items.count>0;
}
static NSString *SSSession(NSString *identifier) {return [[SSPath(WFSSRoot) stringByAppendingPathComponent:@"Sessions"] stringByAppendingPathComponent:identifier];}
static BOOL SSBackendAvailable(void) {
    NSString *root=SSPath(WFSSRuntime);NSDictionary *manifest=SSRead([root stringByAppendingPathComponent:@"module-info.plist"]);
    // Build/audit must explicitly approve runtime packaging; absence is not success.
    if(![manifest[@"schema"] isEqual:@1]||![manifest[@"enabledForDevice"] isEqual:@YES])return NO;
    NSString *brand=[NSString stringWithFormat:@"%016llX",jbrand()];
    if(![manifest[@"brandHex"] isEqual:brand])return NO;
    for(NSString *file in @[@"RootLauncher.sh",@"SleepSyncCoordinator.sh",@"WatchFix_FocusConfigCompatibility.dylib",@"WatchFix_FocusConfigCompatibility.plist",@"WatchFix_HelloReadOnlyObserver.dylib",@"WatchFix_HelloReadOnlyObserver.plist",@"payload.sha256",@"postload.sha256"]){
        struct stat s;if(lstat([[root stringByAppendingPathComponent:file] fileSystemRepresentation],&s)||!S_ISREG(s.st_mode)||s.st_nlink!=1)return NO;
    }
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion==15&&
        NSProcessInfo.processInfo.operatingSystemVersion.minorVersion==4&&NSProcessInfo.processInfo.operatingSystemVersion.patchVersion==0;
}
static BOOL SSRunLauncher(NSString *operation,NSString *identifier,NSError **error) {
    // Fixed bundled launcher via /bin/sh with internally generated arguments.
    // No user-supplied command string, path, PID or service label is accepted.
    posix_spawnattr_t attrs;int rc=posix_spawnattr_init(&attrs);if(rc)return SSErr(error,7,@"无法初始化恢复服务。");
    rc=posix_spawnattr_set_persona_np(&attrs,99,1);
    if(!rc)rc=posix_spawnattr_set_persona_uid_np(&attrs,0);
    if(!rc)rc=posix_spawnattr_set_persona_gid_np(&attrs,0);
    if(![@[@"start",@"recover"] containsObject:operation]||![[[NSUUID alloc] initWithUUIDString:identifier].UUIDString isEqual:identifier]) {posix_spawnattr_destroy(&attrs);return SSErr(error,7,@"无效的固定协调动作。");}
    NSString *program=SSPath(@"/bin/sh");
    NSArray *args=@[program,[SSPath(WFSSRuntime) stringByAppendingPathComponent:@"RootLauncher.sh"],operation,identifier];
    char **argv=(char **)calloc(args.count+1,sizeof(char *));if(!argv)rc=ENOMEM;
    for(NSUInteger i=0;argv&&i<args.count;i++)argv[i]=(char *)[args[i] UTF8String];
    pid_t pid=0;if(!rc)rc=posix_spawn(&pid,program.fileSystemRepresentation,NULL,&attrs,argv,environ);
    free(argv);posix_spawnattr_destroy(&attrs);if(rc)return SSErr(error,8,@"无法启动专用同步协调进程。");
    int status;pid_t result;
    do {result=waitpid(pid,&status,0);}while(result<0&&errno==EINTR);
    return result==pid&&WIFEXITED(status)&&WEXITSTATUS(status)==0 ? YES:SSErr(error,9,@"协调服务未启动；不会自动重试同步。");
}
static NSDictionary *SSIdle(BOOL available) {return @{@"phase":available?@"idle":@"unavailable",@"messageCode":available?@"idle":@"unavailable",@"ackMatched":@NO,@"userVerified":@NO,@"cleanupVerified":@YES,@"backendAvailable":@(available),@"sends":@0};}
@implementation WFSleepSyncBridge
+ (NSDictionary *)snapshot {
    BOOL available=SSBackendAvailable();NSString *identifier=SSCurrentID();
    if(!identifier) {
        if(!SSHasSessionEvidence())return SSIdle(available);
        return @{@"phase":@"recoveryRequired",@"messageCode":@"recoveryRequired",@"ackMatched":@NO,@"userVerified":@NO,@"cleanupVerified":@NO,@"backendAvailable":@(available),@"sends":@0};
    }
    NSDictionary *stored=SSRead([SSSession(identifier) stringByAppendingPathComponent:@"status.plist"]);
    if(!stored)return @{@"sessionID":identifier,@"phase":@"recoveryRequired",@"messageCode":@"recoveryRequired",@"ackMatched":@NO,@"userVerified":@NO,@"cleanupVerified":@NO,@"backendAvailable":@(available),@"sends":@0};
    NSMutableDictionary *result=[stored mutableCopy];result[@"backendAvailable"]=@(available);return result;
}
+ (BOOL)startWithError:(NSError **)error {
    @synchronized(self) {
        if(!SSBackendAvailable())return SSErr(error,10,@"睡眠同步运行组件尚未通过本机安装验证，当前不能开始。");
        if(!SSRootReady(error))return NO;
        int lock=open([[SSPath(WFSSRoot) stringByAppendingPathComponent:@"start.lock"] fileSystemRepresentation],O_WRONLY|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);
        if(lock<0||flock(lock,LOCK_EX|LOCK_NB)){if(lock>=0)close(lock);return SSErr(error,11,@"已有同步请求正在准备。");}
        @try {
            NSDictionary *old=[self snapshot];NSString *phase=old[@"phase"];
            if(![@[@"idle",@"finished",@"cancelled",@"failed"] containsObject:phase]||![old[@"cleanupVerified"] isEqual:@YES])return SSErr(error,12,@"上一会话尚未恢复，不能新建同步。");
            NSString *identifier=NSUUID.UUID.UUIDString,*directory=SSSession(identifier);
            if(mkdir(directory.fileSystemRepresentation,0700))return SSErr(error,13,@"无法新建独立会话。");
            for(NSString *child in @[@"focus",@"identity",@"backup"])if(!SSSafeDirectory([directory stringByAppendingPathComponent:child],error))return NO;
            char boot[128]={};size_t n=sizeof(boot);if(sysctlbyname("kern.bootsessionuuid",boot,&n,NULL,0)||!n||n>sizeof(boot)||boot[n-1])return SSErr(error,14,@"无法读取当前启动标识。");
            // One original deadline is shared by App, runtime and worker; a
            // delayed worker or recovery must never get a fresh seven minutes.
            double now=floor(NSDate.date.timeIntervalSince1970);
            if(!SSWriteTime([directory stringByAppendingPathComponent:@"start-unix"],(long long)now,error)||
               !SSWriteTime([directory stringByAppendingPathComponent:@"deadline-unix"],(long long)now+420,error))return NO;
            NSDictionary *selector=@{@"schema":@1,@"sessionID":identifier,@"bootUUID":[[NSString stringWithUTF8String:boot] uppercaseString],@"startedAt":@(now),@"deadline":@(now+420)};
            NSMutableDictionary *status=[SSIdle(YES) mutableCopy];[status addEntriesFromDictionary:@{@"sessionID":identifier,@"phase":@"preparing",@"messageCode":@"preparing",@"startedAt":@(now),@"deadline":@(now+420),@"cleanupVerified":@NO}];
            if(!SSWrite([directory stringByAppendingPathComponent:@"status.plist"],status,0600,error)||!SSWrite([SSPath(WFSSRoot) stringByAppendingPathComponent:@"current-session.plist"],selector,0600,error))return NO;
            return SSRunLauncher(@"start",identifier,error);
        } @finally {flock(lock,LOCK_UN);close(lock);}
    }
}
+ (BOOL)cancelWithError:(NSError **)error {
    NSString *identifier=SSCurrentID();if(!identifier)return SSErr(error,15,@"没有可取消的会话。");
    NSString *path=[SSSession(identifier) stringByAppendingPathComponent:@"cancel-requested"];
    int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return errno==EEXIST?YES:SSErr(error,16,@"无法请求取消，需检查恢复状态。");
    BOOL ok=fsync(fd)==0;close(fd);return ok;
}
+ (BOOL)recoverWithError:(NSError **)error {
    NSString *identifier=SSCurrentID();if(!identifier)return SSHasSessionEvidence()?SSErr(error,17,@"会话指针损坏；需人工核对恢复，不能新建同步。"):YES;
    if(![self cancelWithError:error])return NO;
    // Recovery launches the SAME already-consumed session. The coordinator's
    // exclusive entered marker makes restart cleanup-only, never a new grant.
    return SSRunLauncher(@"recover",identifier,error);
}
@end
