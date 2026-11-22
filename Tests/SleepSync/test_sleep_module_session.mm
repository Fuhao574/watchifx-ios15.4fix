// Offline host harness: include the production header, never load a device dylib.
// Each invocation runs exactly one scenario so dispatch_once state cannot leak.
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <cstdlib>

static NSString *HostRoot;
static NSString *const SessionA=@"12345678-1234-1234-1234-123456789ABC";
static NSString *const SessionB=@"87654321-4321-4321-4321-CBA987654321";
static NSString *const Boot=@"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
static int MarkerOwner=0;
static NSUInteger MarkerStatCalls;
static NSMutableArray *Errors;
static NSMutableArray *Checks;

// Declared by the generated roothide.h; only the one production module root maps.
const char *WFHostJBRoot(const char *path) {
    if(strcmp(path,"/var/mobile/Library/Application Support/WatchFix/SleepSync"))return NULL;
    return HostRoot.fileSystemRepresentation;
}
static int HostSysctl(const char *name,void *oldp,size_t *oldlenp,void *,size_t) {
    if(strcmp(name,"kern.bootsessionuuid")||!oldp||!oldlenp) {errno=EINVAL;return -1;}
    const char *text=Boot.UTF8String;size_t size=strlen(text)+1;
    if(*oldlenp<size) {errno=ENOMEM;return -1;}
    memcpy(oldp,text,size);*oldlenp=size;return 0;
}
// Fake ONLY identity-enabled's reported owner, after a real nofollow fstatat.
// Mode/type/nlink/inode and every other file's ownership remain real host values.
static int HostFstatat(int fd,const char *name,struct stat *st,int flags) {
    int rc=fstatat(fd,name,st,flags);
    if(!strcmp(name,"identity-enabled")) {
        MarkerStatCalls++;
        if(!rc)st->st_uid=(uid_t)MarkerOwner;
    }
    return rc;
}
#define sysctlbyname HostSysctl
#define fstatat HostFstatat
#include "../../Modules/SleepSync/ModuleSession.h"
#undef fstatat
#undef sysctlbyname

static void Require(BOOL ok,NSString *message) {
    if(!ok)@throw [NSException exceptionWithName:@"FixtureError" reason:message userInfo:nil];
}
static void Check(BOOL ok,NSString *message) {
    [Checks addObject:@{@"check":message,@"passed":@(ok)}];
    if(!ok)[Errors addObject:message];
}
static NSString *Session(NSString *identifier) {
    return [[HostRoot stringByAppendingPathComponent:@"Sessions"] stringByAppendingPathComponent:identifier];
}
static NSString *Child(NSString *name) {return [Session(SessionA) stringByAppendingPathComponent:name];}
static NSString *Selector(void) {return [HostRoot stringByAppendingPathComponent:@"current-session.plist"];}
static void Mkdir(NSString *path) {
    Require(!mkdir(path.fileSystemRepresentation,0700),[NSString stringWithFormat:@"mkdir %@: %s",path,strerror(errno)]);
}
static void Write(NSString *path,NSData *bytes) {
    Require([bytes writeToFile:path options:NSDataWritingAtomic error:NULL],[@"write " stringByAppendingString:path]);
    Require(!chmod(path.fileSystemRepresentation,0600),@"chmod file");
}
static NSMutableDictionary *Value(NSString *identifier) {
    double now=NSDate.date.timeIntervalSince1970;
    return [@{@"schema":@1,@"sessionID":identifier,@"bootUUID":Boot,@"startedAt":@(now-1),@"deadline":@(now+300)} mutableCopy];
}
static void WriteValue(NSDictionary *value) {
    NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    Require(bytes!=nil,@"serialize selector");Write(Selector(),bytes);
}
static void Remove(NSString *path) {
    Require(!unlink(path.fileSystemRepresentation),[@"unlink " stringByAppendingString:path]);
}
static void Move(NSString *from,NSString *to) {
    Require(!rename(from.fileSystemRepresentation,to.fileSystemRepresentation),@"rename fixture");
}
static void Link(NSString *target,NSString *path) {
    Require(!symlink(target.fileSystemRepresentation,path.fileSystemRepresentation),@"symlink fixture");
}
static void MakeSession(NSString *identifier) {
    Mkdir(Session(identifier));
    for(NSString *name in @[@"focus",@"identity",@"backup"])Mkdir([Session(identifier) stringByAppendingPathComponent:name]);
}
static void MakeIdentityMarker(void) {Write(Child(@"identity-enabled"),[@"enabled\n" dataUsingEncoding:NSUTF8StringEncoding]);}
static void Active(void) {Check(WFModuleSessionActive(),@"initial valid session active");}
static void Revoked(void) {
    Check(!WFModuleSessionActive(),@"session rejected");
    Check(WFModuleDirectory("focus")==NULL,@"no focus directory authorization");
    Check(!WFModuleIdentityEnabled(),@"no identity authorization");
}
static void RepairStillRevoked(NSData *original) {
    Write(Selector(),original);Revoked();
}

static void Run(NSString *scenario) {
    NSData *original=[NSData dataWithContentsOfFile:Selector()];
    if([scenario isEqual:@"valid"]) {
        Active();const char *p=WFModuleDirectory("focus");
        Check(p&&[[@(p) stringByStandardizingPath] isEqual:Child(@"focus")],@"focus directory is session A");
        free((void *)p);
        p=WFModuleDirectory("identity");Check(p!=NULL,@"identity directory available");free((void *)p);
        Check(WFModuleDirectory("../backup")==NULL,@"unknown child rejected");
        Check(!WFModuleIdentityEnabled(),@"absent marker never grants identity");
    } else if([scenario isEqual:@"selector_switch"]) {
        Active();MakeSession(SessionB);WriteValue(Value(SessionB));Revoked();RepairStillRevoked(original);
        Check([WFModuleSessionDirectory() isEqual:Session(SessionA)],@"captured directory never switches to B");
    } else if([@[@"missing_after",@"corrupt_after",@"empty_after"] containsObject:scenario]) {
        Active();Remove(Selector());
        if(![scenario isEqual:@"missing_after"])Write(Selector(),[scenario isEqual:@"empty_after"]?[NSData data]:[@"not a plist" dataUsingEncoding:NSUTF8StringEncoding]);
        Revoked();RepairStillRevoked(original);
    } else if([@[@"missing_startup",@"corrupt_startup"] containsObject:scenario]) {
        Remove(Selector());
        if([scenario isEqual:@"corrupt_startup"])Write(Selector(),[@"bad plist" dataUsingEncoding:NSUTF8StringEncoding]);
        Check(WFModuleSessionDirectory()==nil,@"startup capture fails closed");
        Write(Selector(),original);Revoked();
    } else if([scenario hasPrefix:@"invalid_"]) {
        NSMutableDictionary *v=Value(SessionA);NSString *kind=[scenario substringFromIndex:8];
        double now=NSDate.date.timeIntervalSince1970;
        if([kind isEqual:@"boot"])v[@"bootUUID"]=SessionB;
        else if([kind isEqual:@"uuid"])v[@"sessionID"]=@"../../escape";
        else if([kind isEqual:@"lowercase_uuid"])v[@"sessionID"]=SessionA.lowercaseString;
        else if([kind isEqual:@"schema"])v[@"schema"]=@2;
        else if([kind isEqual:@"extra_key"])v[@"extra"]=@1;
        else if([kind isEqual:@"expired"]) {v[@"startedAt"]=@(now-100);v[@"deadline"]=@(now-1);}
        else if([kind isEqual:@"future"]) {v[@"startedAt"]=@(now+100);v[@"deadline"]=@(now+200);}
        else if([kind isEqual:@"long_lease"])v[@"deadline"]=@(now+500);
        else if([kind isEqual:@"time_type"])v[@"startedAt"]=@"123";
        else Require(NO,@"unknown invalid selector scenario");
        WriteValue(v);Revoked();RepairStillRevoked(original);
    } else if([scenario isEqual:@"selector_mode"]) {
        Require(!chmod(Selector().fileSystemRepresentation,0644),@"chmod selector");Revoked();
    } else if([scenario isEqual:@"selector_symlink"]) {
        NSString *saved=[HostRoot stringByAppendingPathComponent:@"saved-selector"];
        Move(Selector(),saved);Link(saved,Selector());Revoked();
    } else if([scenario isEqual:@"selector_hardlink"]) {
        Require(!link(Selector().fileSystemRepresentation,[HostRoot stringByAppendingPathComponent:@"linked-selector"].fileSystemRepresentation),@"hardlink selector");Revoked();
    } else if([@[@"root_mode",@"sessions_mode",@"session_mode"] containsObject:scenario]) {
        Active();NSString *p=[scenario isEqual:@"root_mode"]?HostRoot:([scenario isEqual:@"sessions_mode"]?[HostRoot stringByAppendingPathComponent:@"Sessions"]:Session(SessionA));
        Require(!chmod(p.fileSystemRepresentation,0755),@"chmod directory");Revoked();
        Require(!chmod(p.fileSystemRepresentation,0700),@"restore directory mode");Revoked();
    } else if([scenario isEqual:@"directory_replace"]) {
        Active();Move(Session(SessionA),[Session(SessionA) stringByAppendingString:@".old"]);MakeSession(SessionA);Revoked();
    } else if([scenario isEqual:@"session_symlink"]||[scenario isEqual:@"sessions_symlink"]||[scenario isEqual:@"root_symlink"]) {
        Active();NSString *p=[scenario isEqual:@"root_symlink"]?HostRoot:([scenario isEqual:@"sessions_symlink"]?[HostRoot stringByAppendingPathComponent:@"Sessions"]:Session(SessionA));
        NSString *saved=[p stringByAppendingString:@".old"];Move(p,saved);Link(saved,p);Revoked();
    } else if([scenario isEqual:@"child_symlink"]) {
        NSString *p=Child(@"focus"),*saved=[p stringByAppendingString:@".old"];
        Move(p,saved);Link(saved,p);Active();Check(WFModuleDirectory("focus")==NULL,@"symlink child rejected");
    } else if([scenario isEqual:@"cancel"]||[scenario isEqual:@"closed"]) {
        Active();NSString *p=Child([scenario isEqual:@"cancel"]?@"cancel-requested":@"closed");
        Write(p,[NSData data]);Revoked();Remove(p);Revoked();
    } else if([scenario hasPrefix:@"marker_"]||[scenario isEqual:@"identity_once"]||[scenario isEqual:@"receipt_existing"]) {
        Active();MakeIdentityMarker();
        if([scenario isEqual:@"marker_bad_mode"]) {
            Require(!chmod(Child(@"identity-enabled").fileSystemRepresentation,0644),@"chmod marker");
        } else if([scenario isEqual:@"marker_bad_owner"])MarkerOwner=502;
        else if([scenario isEqual:@"marker_mobile_owner"])MarkerOwner=501;
        else if([scenario isEqual:@"marker_symlink"]) {
            Move(Child(@"identity-enabled"),Child(@"saved-marker"));Link(Child(@"saved-marker"),Child(@"identity-enabled"));
        } else if([scenario isEqual:@"marker_hardlink"]) {
            Require(!link(Child(@"identity-enabled").fileSystemRepresentation,Child(@"linked-marker").fileSystemRepresentation),@"hardlink marker");
        } else if([scenario isEqual:@"marker_directory"]) {
            Remove(Child(@"identity-enabled"));Mkdir(Child(@"identity-enabled"));
        } else if([scenario isEqual:@"receipt_existing"])Write(Child(@"identity-spent"),[@"already consumed" dataUsingEncoding:NSUTF8StringEncoding]);
        if([scenario isEqual:@"identity_once"]) {
            Check(WFModuleIdentityEnabled(),@"first native identity claim succeeds");
            NSData *receipt=[NSData dataWithContentsOfFile:Child(@"identity-spent")];
            Check([receipt isEqual:[@"IDENTITY-CANDIDATE-ATTEMPT-CONSUMED\n" dataUsingEncoding:NSUTF8StringEncoding]],@"native receipt content persisted");
            struct stat st;Check(!lstat(Child(@"identity-spent").fileSystemRepresentation,&st)&&S_ISREG(st.st_mode)&&st.st_uid==501&&(st.st_mode&07777)==0600&&st.st_nlink==1,@"receipt is real host uid 501 private file");
            Check(!WFModuleIdentityEnabled(),@"second identity claim denied");
            Check([[NSData dataWithContentsOfFile:Child(@"identity-spent")] isEqual:receipt],@"denied claim preserves receipt");
        } else {
            Check(!WFModuleIdentityEnabled(),@"unsafe marker or spent receipt denied");
            if(![scenario isEqual:@"receipt_existing"])Check(access(Child(@"identity-spent").fileSystemRepresentation,F_OK)!=0,@"rejected marker does not spend identity");
        }
        Check(MarkerStatCalls>0,@"actual production marker fstatat reached");
    } else Require(NO,[@"unknown scenario: " stringByAppendingString:scenario]);
}

int main(int argc,char **argv) {
    @autoreleasepool {
        Errors=[NSMutableArray new];Checks=[NSMutableArray new];
        NSString *scenario=argc>1?@(argv[1]):@"missing argument";
        @try {
            Require(argc==3,@"usage: host-test SCENARIO FIXTURE_ROOT");
            Require(getuid()==501&&geteuid()==501,@"host tests require real uid/euid 501 (no ownership mocking for session tree)");
            HostRoot=@(argv[2]);Mkdir(HostRoot);Mkdir([HostRoot stringByAppendingPathComponent:@"Sessions"]);
            MakeSession(SessionA);WriteValue(Value(SessionA));Run(scenario);
        } @catch(NSException *exception) {
            [Errors addObject:[NSString stringWithFormat:@"%@: %@",exception.name,exception.reason]];
        }
        NSDictionary *result=@{@"scenario":scenario,@"passed":@(Errors.count==0),@"errors":Errors,@"checks":Checks,@"markerStatCalls":@(MarkerStatCalls)};
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        if(json)fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);
        return Errors.count?1:0;
    }
}
