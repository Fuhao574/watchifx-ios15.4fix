// Host only: directly include the actual module lease and session gates.
// Real filesystem ownership/modes/receipts; no daemon, Apple private code or send.
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <fcntl.h>
#include <cassert>
#include <cstring>
#include <cstdarg>
static NSString *Root;
static NSString *const Boot=@"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
static NSString *const ID=@"12345678-1234-1234-1234-123456789ABC";
static double Wall, Uptime=100;
const char *WFHostJBRoot(const char *path) {
    assert(!strcmp(path,"/var/mobile/Library/Application Support/WatchFix/SleepSync"));
    return Root.fileSystemRepresentation;
}
static int HostSysctl(const char *name,void *buffer,size_t *length,void *,size_t) {
    assert(!strcmp(name,"kern.bootsessionuuid"));
    const char *text=Boot.UTF8String;size_t n=strlen(text)+1;
    assert(buffer&&length&&*length>=n);memcpy(buffer,text,n);*length=n;return 0;
}
void WFLog(const char *,NSString *,...) {} // no protocol/logging substitute assertions
static double WFTrialNow(void) {return Uptime;}
static double WFTrialWallNow(void) {return Wall;}
static NSString *WFTrialBoot(void) {return Boot;}
#define WF_TRIAL2_HOST_TEST 1
#define sysctlbyname HostSysctl
#include "TrialPermit.h"
#undef sysctlbyname

static void Directory(NSString *path) {assert(!mkdir(path.fileSystemRepresentation,0700));}
static void Plist(NSString *path,NSDictionary *value) {
    NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    assert(bytes&&[bytes writeToFile:path options:NSDataWritingAtomic error:NULL]);
    assert(!chmod(path.fileSystemRepresentation,0600));
}
int main(int argc,char **argv) {
    assert(argc==3 && getuid()==501 && geteuid()==501);
    @autoreleasepool {
        NSString *scenario=@(argv[1]);Root=@(argv[2]);
        Wall=floor(NSDate.date.timeIntervalSince1970);
        Directory(Root);Directory([Root stringByAppendingPathComponent:@"Sessions"]);
        NSString *session=[[Root stringByAppendingPathComponent:@"Sessions"] stringByAppendingPathComponent:ID];
        Directory(session);
        NSString *focus=[session stringByAppendingPathComponent:@"focus"];
        Directory(focus);Directory([session stringByAppendingPathComponent:@"identity"]);
        NSString *selector=[Root stringByAppendingPathComponent:@"current-session.plist"];
        NSDictionary *selection=@{@"schema":@1,@"sessionID":ID,@"bootUUID":Boot,@"startedAt":@(Wall-1),@"deadline":@(Wall+300)};
        Plist(selector,selection);
        NSString *grant=[focus stringByAppendingPathComponent:@"policy-grant.plist"];
        NSDictionary *permission=@{@"schema":@"sleep-module1-policy-v1",@"scope":@"one-additive-sleep-update-no-control",@"bootUUID":Boot,@"issuedUnix":@(Wall),@"deadlineUnix":@(Wall+180)};
        Plist(grant,permission);
        BOOL initialDenied=[@[@"grant-mode",@"directory-mode",@"receipt-existing",@"expired"] containsObject:scenario];
        if([scenario isEqual:@"grant-mode"])assert(!chmod(grant.fileSystemRepresentation,0644));
        if([scenario isEqual:@"directory-mode"])assert(!chmod(focus.fileSystemRepresentation,0755));
        if([scenario isEqual:@"receipt-existing"]) {
            int fd=open([[focus stringByAppendingPathComponent:@"session-spent"] fileSystemRepresentation],O_CREAT|O_EXCL|O_WRONLY,0600);assert(fd>=0);close(fd);
        }
        if([scenario isEqual:@"expired"])Wall+=180;
        WFTrialInitialize();WFTrialSetHooksReady(YES);
        assert(WFTrialEnabled()==!initialDenied);
        if(initialDenied) {
            assert(!WFTrialClaimReceipt(@"policy-spent",YES));
            assert(access([[focus stringByAppendingPathComponent:@"policy-spent"] fileSystemRepresentation],F_OK));
            return 0;
        }
        assert(WFTrialGrantBytes&&WFTrialDirectory>=0&&WFTrialPolicyReady());
        if([scenario isEqual:@"valid"]) {
            assert(!WFTrialClaimReceipt(@"wrong",YES));
            assert(!WFTrialClaimReceipt(@"policy-spent",NO));
            assert(WFTrialClaimReceipt(@"policy-spent",YES));
            assert(!WFTrialClaimReceipt(@"policy-spent",YES));
            struct stat receipt;assert(!stat([[focus stringByAppendingPathComponent:@"policy-spent"] fileSystemRepresentation],&receipt));
            assert(receipt.st_uid==501&&(receipt.st_mode&07777)==0600&&receipt.st_nlink==1);
        } else {
            NSString *changed=nil;
            if([scenario isEqual:@"cancel"]||[scenario isEqual:@"closed"]) {
                changed=[session stringByAppendingPathComponent:[scenario isEqual:@"cancel"]?@"cancel-requested":@"closed"];
                int fd=open(changed.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY,0600);assert(fd>=0);close(fd);
            } else if([scenario isEqual:@"grant-replaced"]) Plist(grant,permission);
            else if([scenario isEqual:@"selector-replaced"]) {
                NSMutableDictionary *other=[selection mutableCopy];other[@"deadline"]=@(Wall+301);Plist(selector,other);
            } else if([scenario isEqual:@"lease-expired"]) {Wall+=180;Uptime+=180;}
            else if([scenario isEqual:@"hooks-disabled"])WFTrialSetHooksReady(NO);
            else assert(false);
            assert(!WFTrialEnabled()&&!WFTrialClaimReceipt(@"policy-spent",YES));
            // Repair cannot replenish a revoked lease or erase consumed receipts.
            if(changed)assert(!unlink(changed.fileSystemRepresentation));
            if([scenario isEqual:@"grant-replaced"])Plist(grant,permission);
            if([scenario isEqual:@"selector-replaced"])Plist(selector,selection);
            WFTrialSetHooksReady(YES);
            assert(!WFTrialEnabled()&&!WFTrialClaimReceipt(@"policy-spent",YES));
        }
        printf("PASS actual module permit: %s\n",argv[1]);
    }
    return 0;
}
