// Direct production bridge inclusion, offline filesystem + plugin-state mocks.
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cassert>
#include <cerrno>
#include <cstring>
static NSString *Fixture;
static BOOL Registered=YES;
static int Changes, SpawnCalls;
const char *HostJBRoot(const char *path) {
    return strdup([[Fixture stringByAppendingString:@(path)] fileSystemRepresentation]);
}
static uint64_t jbrand(void) {return 1;}
#import "../../App/Bridge/SleepSync/SleepSyncBridge.xm"
extern "C" int posix_spawnattr_set_persona_np(const posix_spawnattr_t *,uid_t,uint32_t) {++SpawnCalls;return ENOTSUP;}
extern "C" int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *,uid_t) {return ENOTSUP;}
extern "C" int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *,gid_t) {return ENOTSUP;}
@implementation WFPluginBridge
+ (NSDictionary *)pluginStates {return @{@"FocusConfigCompatibility":@(Registered)};}
@end
@implementation WFPluginConfigurationContext
- (NSString *)pluginIdentifier {return @"FocusConfigCompatibility";}
- (BOOL)installUsingDefaultImplementation:(NSError **)error {(void)error;Registered=YES;++Changes;return YES;}
- (BOOL)removeUsingDefaultImplementation:(NSError **)error {(void)error;Registered=NO;++Changes;return YES;}
@end
static void Dirs(NSString *p) {
    assert([[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL]);
}
static void Plist(NSString *p,NSDictionary *value) {
    assert([value writeToFile:p atomically:YES]);assert(!chmod(p.fileSystemRepresentation,0600));
}
int main(int argc,char **argv) {
    assert(argc==3&&geteuid()==501);
    @autoreleasepool {
        Fixture=@(argv[2]);NSString *scenario=@(argv[1]);
        Dirs(SSPath(@"/var/mobile/Library/Application Support"));
        assert(SSRootReady(NULL));
        NSString *identifier=@"12345678-1234-1234-1234-123456789ABC";
        NSString *session=SSSession(identifier);
        BOOL reject=NO,enable=[scenario isEqual:@"reinstall"];
        if(enable)Registered=NO;
        if(![scenario isEqual:@"idle"] && !enable) {
            Dirs(session);
            Plist([SSPath(WFSSRoot) stringByAppendingPathComponent:@"current-session.plist"],@{@"sessionID":identifier});
            NSMutableDictionary *value=[@{@"sessionID":identifier,@"phase":@"failed",@"cleanupVerified":@YES} mutableCopy];
            if([scenario isEqual:@"active"]){value[@"phase"]=@"waitingForSave";value[@"cleanupVerified"]=@NO;reject=YES;}
            if([scenario isEqual:@"dirty"]){value[@"cleanupVerified"]=@NO;reject=YES;}
            if([scenario isEqual:@"missing-status"]){reject=YES;}
            else Plist([session stringByAppendingPathComponent:@"status.plist"],value);
            if([scenario isEqual:@"residual"] || [scenario isEqual:@"dangling-filter"]) {
                NSString *p=SSPath(@"/usr/lib/TweakInject/WatchFix_FocusConfigCompatibility.plist");
                Dirs(p.stringByDeletingLastPathComponent);
                if([scenario isEqual:@"residual"])assert([[@"unknown" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:p atomically:YES]);
                else assert(!symlink("/nonexistent-test-target",p.fileSystemRepresentation));
                reject=YES;
            }
        }
        NSError *error=nil;
        WFPluginConfigurationContext *context=[WFPluginConfigurationContext alloc];
        BOOL result=[WFSleepSyncBridge setRegistered:enable context:context error:&error];
        assert(result==!reject);
        assert(Changes==(reject?0:1));
        assert(Registered==(reject?YES:enable));
        assert((error!=nil)==reject);
        assert(SpawnCalls==0); // never start/recover/restart as a deletion side effect
        printf("PASS registration %s\n",argv[1]);
    }
    return 0;
}
