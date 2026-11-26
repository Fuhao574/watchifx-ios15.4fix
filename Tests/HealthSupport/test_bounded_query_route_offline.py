"""Real grant receipt -> public installer -> owned ObjC replacements, no device.

Only host/identity/caller fixture boundaries are substituted in the test TU.
Session file I/O and public install/stop/deadline paths execute actual code.
Each scenario runs in its own process; no rearming/reset of production state.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_query_route_probe_offline import MAIN, INSTALL_FIXTURES, TEST, PROBE, ADAPTER, HERE

EXTRA = r'''
#include "ProbeSession.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
static WFHSProbeClock fixtureClock={"12345678-1234-1234-1234-123456789ABC",1000,50};
static int fixtureDirectory,scenario;
static int FixtureClock(WFHSProbeClock *clock){*clock=fixtureClock;return 0;}
static id FixtureIdentity(NSInteger boundary,Class cls);
static Class FixtureLookup(const char *name);
static void FixtureAssertReceiptLocksReleased(void);
#if defined(WFHS_ROUTE_RECEIPT_LOG)
static unsigned receiptEvents[5],receiptCount;
void FixtureReceiptLog(const char *line) {
 FixtureAssertReceiptLocksReleased();
 assert(!strncmp(line,"WFHS_QROUTE_RECEIPT_V1 ",22));assert(strlen(line)<512);
 unsigned event=0;assert(sscanf(line,"WFHS_QROUTE_RECEIPT_V1 event=%u",&event)==1&&event>=1&&event<=4);
 assert(!receiptEvents[event]);receiptEvents[event]=1;++receiptCount;assert(receiptCount<=4);
 assert(strstr(line,"receive=0 modified=0 samples=0"));
 if(event==WFHSProbeReceiptInstallBegin) {
  assert(strstr(line,"result=0 returned=0 nativeSuccess=0 schema=3 installed=0 enabled=0 installStatus=0 lifecycle=1 session=0"));
 }
 if(event==WFHSProbeReceiptInstallResult) {
  const char *expected=scenario==1?"result=7 returned=0 nativeSuccess=0 schema=3 installed=0 enabled=0 installStatus=7 lifecycle=3 session=5":
      scenario==5?"result=7 returned=0 nativeSuccess=0 schema=3 installed=1 enabled=0 installStatus=7 lifecycle=3 session=5":
      scenario==3?"result=9 returned=0 nativeSuccess=0 schema=3 installed=0 enabled=0 installStatus=9 lifecycle=4 session=3":
      scenario==4?"result=9 returned=0 nativeSuccess=0 schema=3 installed=0 enabled=0 installStatus=9 lifecycle=4 session=2":
      "result=0 returned=0 nativeSuccess=0 schema=3 installed=1 enabled=1 installStatus=0 lifecycle=2 session=1";
  assert(strstr(line,expected));
 }
 if(event==WFHSProbeReceiptEnumerationExit) {
  assert(strstr(line,scenario==6?"returned=0 nativeSuccess=0":scenario==7?"returned=1 nativeSuccess=1":"returned=1 nativeSuccess=0"));
 }
 if(event==WFHSProbeReceiptObservationClosed)assert(strstr(line,"enabled=0")&&strstr(line,"lifecycle=3"));
}
#endif
'''
SUFFIX = r'''
static void FixtureAssertReceiptLocksReleased(void) {
 assert(!pthread_mutex_trylock(&lifecycleLock));pthread_mutex_unlock(&lifecycleLock);
 assert(!pthread_mutex_trylock(&probeSession.lock));pthread_mutex_unlock(&probeSession.lock);
 if(registryLock){assert([registryLock tryLock]);[registryLock unlock];}
}
@interface OwnedMethodIdentity : NSObject
- (BOOL)stillMatches;
@end
@implementation OwnedMethodIdentity
- (BOOL)stillMatches{return YES;}
@end
static id FixtureIdentity(NSInteger boundary,Class cls){(void)boundary;assert(cls);return [OwnedMethodIdentity new];}
static Class FixtureLookup(const char *name) {
 if(!strcmp(name,"HDSleepDaySummaryEnumerator"))return FixtureProbeEnumerator.class;
 assert(!strcmp(name,"HDSleepDaySummaryBuilder"));return FixtureProbeDay.class;
}
static void encode64(unsigned char *p,uint64_t value){for(unsigned i=0;i<8;++i)p[i]=(unsigned char)(value>>(i*8));}
static void FixtureBeforeReplacement(void) {
 struct stat st;
 assert(!fstatat(fixtureDirectory,"probe-spent-v1",&st,AT_SYMLINK_NOFOLLOW)&&st.st_size==96);
 assert(atomic_load_explicit(&originalsReady,memory_order_acquire));
 assert(!atomic_load(&observationEnabled));
}
static void FixtureAfterReplacement(void) {
 assert(!atomic_load(&observationEnabled));
 if((scenario==1&&replacementCalls==2)||(scenario==5&&replacementCalls==4)){fixtureClock.monotonic=130;fixtureClock.wall=1079;}
}
int main(int argc,char **argv) {
 assert(argc==3);scenario=atoi(argv[2]);fixtureDirectory=open(argv[1],O_RDONLY|O_DIRECTORY);assert(fixtureDirectory>=0);
 @autoreleasepool {
  expectedProfile=[NSObject new];expectedCache=[NSObject new];expectedDebug=[NSObject new];summaryValue=[NSObject new];
  errorValue=[NSError errorWithDomain:@"OriginalFixture" code:42 userInfo:nil];
  exceptionValue=[NSException exceptionWithName:@"Original" reason:nil userInfo:nil];
  unsigned char bytes[96]={0};memcpy(bytes,"WFHS-PROBE-G1\n",14);memcpy(bytes+16,fixtureClock.boot,37);
  encode64(bytes+56,990);encode64(bytes+64,1080);encode64(bytes+72,90);bytes[80]=1;
  if(scenario!=4) {
   int fd=openat(fixtureDirectory,"probe-grant-v1",O_CREAT|O_EXCL|O_WRONLY,0600);assert(fd>=0&&write(fd,bytes,96)==96);close(fd);
  }
  if(scenario==3){int fd=openat(fixtureDirectory,"probe-spent-v1",O_CREAT|O_EXCL|O_WRONLY,0600);assert(fd>=0);close(fd);}
  installationInterleave=YES;
  int result=WFHSInstallQueryRouteProbeSessionV1(fixtureDirectory);
  installationInterleave=NO;
  if(scenario==3||scenario==4) {
   assert(result==9&&replacementCalls==0&&!atomic_load(&originalsReady));
   assert(WFHSInstallQueryRouteProbeSessionV1(fixtureDirectory)==1);
#if defined(WFHS_ROUTE_RECEIPT_LOG)
   assert(receiptEvents[1]&&receiptEvents[2]&&!receiptEvents[3]&&receiptCount==2);
#endif
   return 0;
  }
  if(scenario==1||scenario==5) {
   assert(result==7&&replacementCalls==(scenario==1?2:4)&&!atomic_load(&observationEnabled));
   WFHSQueryRouteProbeReport report=WFHSReadQueryRouteProbeReport();
   assert(report.installStatus==(uint32_t)result&&report.installed==(scenario==5?1u:0u));
   assert(WFHSQueryRouteProbeSessionStateV1()==WFHSProbeSessionExpired);
   // Partially installed entry set still runs all original query behavior.
   installationInterleave=YES;FixtureQueryDuringInstall(NULL);installationInterleave=NO;
  } else {
   assert(result==0&&replacementCalls==4&&atomic_load(&observationEnabled));
   id e=[[FixtureProbeEnumerator alloc]initWithProfile:expectedProfile calendarCache:expectedCache morningIndexRange:expectedRange ascending:YES requireSleepAnalysis:NO onlySleepAnalysis:YES debugIdentifier:expectedDebug];
  if(scenario==2){fixtureClock.wall=1079;fixtureClock.monotonic=130;}
   if(scenario==6)throwOriginal=YES;
   NSError *error=nil;__block unsigned count=0;
   BOOL caught=NO;
   @try {
    BOOL nativeResult=[e enumerateWithError:&error handler:^(id summary,BOOL *stop){assert(summary==summaryValue);++count;*stop=YES;}];
    assert(nativeResult==(scenario==7));
   }
   @catch(NSException *exception){caught=exception==exceptionValue;}
   assert(caught==(scenario==6)&&!atomic_load(&inFlightWrappers));
   if(scenario==6)assert(count==0&&!error);
   else assert(count==1&&error==(scenario==7?nil:errorValue));
   if(scenario==2) {
    assert(!atomic_load(&observationEnabled)&&WFHSQueryRouteProbeSessionStateV1()==WFHSProbeSessionExpired);
    assert(!atomic_load(&enumerationCount)&&!atomic_load(&createCount));
   } else assert(atomic_load(&enumerationCount)==1&&atomic_load(&createCount)==1);
  }
  assert(WFHSInstallQueryRouteProbeSessionV1(fixtureDirectory)==1);
  uint32_t reason=WFHSQueryRouteProbeSessionStateV1();
  WFHSStopQueryRouteProbe();assert(!atomic_load(&observationEnabled));
  if(reason!=WFHSProbeSessionActive)assert(WFHSQueryRouteProbeSessionStateV1()==reason);
#if defined(WFHS_ROUTE_RECEIPT_LOG)
  assert(receiptEvents[1]&&receiptEvents[2]&&receiptEvents[4]);
   if(scenario==0||scenario==6||scenario==7)assert(receiptEvents[3]&&receiptCount==4);
  // Repeated stop and calls never refund an event slot or produce a log stream.
  unsigned before=receiptCount;WFHSStopQueryRouteProbe();assert(before==receiptCount);
#endif
  struct stat st;assert(!fstatat(fixtureDirectory,"probe-spent-v1",&st,AT_SYMLINK_NOFOLLOW));
  puts("PASS durable receipt precedes method mutation; install/query expiry stops observation without changing original calls");
 }
 close(fixtureDirectory);return 0;
}
'''


class BoundedRouteTests(unittest.TestCase):
    def run_fixture(self,receipt=False):
        text=(PROBE/'QueryRouteProbe.m').read_text()
        a=text.index('static BOOL WFHSProbeHost(');b=text.index('static BOOL WFHSProbeCaller(',a)
        text=text[:a]+'static BOOL WFHSProbeHost(void){return YES;}\n'+text[b:]
        a=text.index('static BOOL WFHSProbeCaller(');b=text.index('static void WFHSProbeFail(',a)
        text=text[:a]+'static BOOL WFHSProbeCaller(const void *address,uintptr_t offset){(void)address;(void)offset;return fixtureCaller;}\n'+text[b:]
        text=text.replace('WFHSProbeSystemClock','FixtureClock').replace('WFHSCheckIOS154Boundary','FixtureIdentity').replace('objc_lookUpClass','FixtureLookup')
        text=text.replace('method_setImplementation(','FixtureSetImplementation(')
        text=text.replace('typedef struct {int64_t start,duration;} WFHSProbeRange;',MAIN+EXTRA+'\ntypedef struct {int64_t start,duration;} WFHSProbeRange;')
        fixtures=TEST[:TEST.index('static void FixtureAfterReplacement(void) {')].replace('static unsigned installationCallbacks;','')
        fixtures=fixtures.replace('if(error)*error=errorValue;return NO;', 'if(error)*error=scenario==7?nil:errorValue;return scenario==7;')
        installs=INSTALL_FIXTURES.replace(' ++replacementCalls;',' FixtureBeforeReplacement();++replacementCalls;')
        source=text+'\nstatic void FixtureBeforeReplacement(void);\n'+installs+fixtures+SUFFIX
        with tempfile.TemporaryDirectory(prefix='bounded-route-',dir=HERE) as tmp:
            work=Path(tmp);(work/'main.m').write_text(source)
            if receipt:
                (work/'os').mkdir()
                (work/'os/log.h').write_text('#define OS_LOG_DEFAULT 0\nvoid FixtureReceiptLog(const char *line);\n#define os_log_error(log,format,line) FixtureReceiptLog(line)\n')
            for opt in ('-O0','-O2'):
                command=['xcrun','clang','-fobjc-arc','-fobjc-arc-exceptions',opt,'-Wall','-Wextra','-Werror','-Wno-unused-function',
                         '-DWFHS_QUERY_ROUTE_PROBE=1','-DWFHS_ROUTE_BOUNDED_SESSION=1','-fsanitize=address,undefined','-framework','Foundation',
                         '-I',str(PROBE),'-I',str(ADAPTER),str(work/'main.m'),str(PROBE/'ProbeSession.c'),'-o',str(work/'test')]
                if receipt:
                    command+=['-DWFHS_ROUTE_RECEIPT_LOG=1','-I',str(work),str(PROBE/'ProbeReceipt.c')]
                result=subprocess.run(command,capture_output=True,text=True,timeout=60)
                self.assertEqual(result.returncode,0,result.stderr)
                for scenario in range(8):
                    state=work/(opt+str(scenario));state.mkdir(mode=0o700)
                    run=subprocess.run([str(work/'test'),str(state),str(scenario)],capture_output=True,text=True,timeout=15)
                    self.assertEqual(run.returncode,0,run.stderr)

    def test_real_claim_before_public_install_and_passive_expiry(self):
        self.run_fixture()

    def test_bounded_receipts_match_actual_install_query_and_stop(self):
        self.run_fixture(receipt=True)


if __name__=='__main__':unittest.main(verbosity=2)
