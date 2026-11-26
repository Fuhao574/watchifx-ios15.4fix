"""Actual owned-process constructor -> real claim -> public hooks -> query.

Fake host/Apple identity/caller/clock/class lookup only. Never executes iOS code.
Parent prepares a private synthetic grant BEFORE starting the child process.
"""
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from test_query_route_probe_offline import MAIN, INSTALL_FIXTURES, TEST, PROBE, ADAPTER, HERE
from test_bounded_query_route_offline import EXTRA, SUFFIX

CHILD=r'''
int main(void) {
 @autoreleasepool {
  assert(WFHSQueryRouteStartupStateV1()==WFHSRouteStartupInstallerReturned);
  WFHSQueryRouteProbeReport state=WFHSReadQueryRouteProbeReport();
  assert(state.installed&&state.enabled&&state.lifecycle==WFHSRouteObserving&&replacementCalls==4);
  assert(receiptEvents[1]&&receiptEvents[2]&&receiptCount==2);
  expectedProfile=[NSObject new];expectedCache=[NSObject new];expectedDebug=[NSObject new];summaryValue=[NSObject new];
  errorValue=[NSError errorWithDomain:@"OriginalFixture" code:42 userInfo:nil];
  id e=[[FixtureProbeEnumerator alloc]initWithProfile:expectedProfile calendarCache:expectedCache morningIndexRange:expectedRange ascending:YES requireSleepAnalysis:NO onlySleepAnalysis:YES debugIdentifier:expectedDebug];
  NSError *error=nil;__block unsigned count=0;
  assert(![e enumerateWithError:&error handler:^(id summary,BOOL *stop){assert(summary==summaryValue);++count;*stop=YES;}]);
  assert(count==1&&error==errorValue&&receiptEvents[3]);
  WFHSStopQueryRouteProbe();assert(receiptEvents[4]&&receiptCount==4);
  assert(!WFHSReadQueryRouteProbeReport().enabled&&!WFHSReadQueryRouteProbeReport().inFlightWrappers);
  puts("PASS actual premain owned constructor/receipt claim/public installer/real own query/stop/no device activation");
 }
}
'''


class PremainIntegrationTests(unittest.TestCase):
    def test_actual_constructor_to_owned_query(self):
        text=(PROBE/'QueryRouteProbe.m').read_text()
        a=text.index('static BOOL WFHSProbeHost(');b=text.index('static BOOL WFHSProbeCaller(',a)
        text=text[:a]+'static BOOL WFHSProbeHost(void){return YES;}\nint WFHSQueryRouteHostMatches(void){return WFHSProbeHost();}\n'+text[b:]
        a=text.index('static BOOL WFHSProbeCaller(');b=text.index('static void WFHSProbeFail(',a)
        text=text[:a]+'static BOOL WFHSProbeCaller(const void *address,uintptr_t offset){(void)address;(void)offset;return fixtureCaller;}\n'+text[b:]
        text=text.replace('WFHSProbeSystemClock','FixtureClock').replace('WFHSCheckIOS154Boundary','FixtureIdentity').replace('objc_lookUpClass','FixtureLookup')
        text=text.replace('method_setImplementation(','FixtureSetImplementation(')
        extra=EXTRA.replace('static int fixtureDirectory,scenario;','static int scenario;')
        text=text.replace('typedef struct {int64_t start,duration;} WFHSProbeRange;',MAIN+extra+'\ntypedef struct {int64_t start,duration;} WFHSProbeRange;')
        fixtures=TEST[:TEST.index('static void FixtureAfterReplacement(void) {')].replace('static unsigned installationCallbacks;','')
        helpers=SUFFIX[:SUFFIX.index('int main(')]
        helpers=helpers.replace('fstatat(fixtureDirectory,"probe-spent-v1"','fstatat(AT_FDCWD,WFHS_ROUTE_STARTUP_DIRECTORY "/probe-spent-v1"')
        source='#include "QueryRouteStartupPrivate.h"\n'+text+'\nstatic void FixtureBeforeReplacement(void);\n'+INSTALL_FIXTURES.replace(' ++replacementCalls;',' FixtureBeforeReplacement();++replacementCalls;')+fixtures+helpers+'\n#include "StartupController.m"\n'+CHILD
        with tempfile.TemporaryDirectory(prefix='premain-route-',dir=HERE) as tmp:
            work=Path(tmp);(work/'main.m').write_text(source);(work/'os').mkdir()
            (work/'os/log.h').write_text('#define OS_LOG_DEFAULT 0\nvoid FixtureReceiptLog(const char *line);\n#define os_log_error(log,format,line) FixtureReceiptLog(line)\n')
            for opt in ('-O0','-O2'):
                state=work/opt;state.mkdir(mode=0o700);st=state.stat()
                (work/'QueryRouteStartupPrivate.h').write_text(
                    '#define WFHS_ROUTE_STARTUP_ACTIVATION_REVIEWED 1\n'
                    f'#define WFHS_ROUTE_STARTUP_DIRECTORY "{state}"\n'
                    f'#define WFHS_ROUTE_STARTUP_DEVICE {st.st_dev}ULL\n'
                    f'#define WFHS_ROUTE_STARTUP_INODE {st.st_ino}ULL\n')
                grant=state/'probe-grant-v1'
                grant.write_bytes(b'WFHS-PROBE-G1\n'.ljust(16,b'\0')+b'12345678-1234-1234-1234-123456789ABC'.ljust(40,b'\0')+struct.pack('<QQQ',990,1080,90)+b'\1'+b'\0'*15)
                grant.chmod(0o600)
                command=['xcrun','clang','-fobjc-arc','-fobjc-arc-exceptions',opt,'-Wall','-Wextra','-Werror','-Wno-unused-function',
                    '-DWFHS_QUERY_ROUTE_PROBE=1','-DWFHS_ROUTE_BOUNDED_SESSION=1','-DWFHS_ROUTE_RECEIPT_LOG=1',
                    '-DWFHS_ROUTE_STARTUP_CONTROLLER=1','-DWFHS_ROUTE_STARTUP_PRIVATE_CONFIG=1',
                    '-fsanitize=address,undefined','-framework','Foundation','-I',str(work),'-I',str(PROBE),'-I',str(ADAPTER),
                    str(work/'main.m'),str(PROBE/'ProbeSession.c'),str(PROBE/'ProbeReceipt.c'),'-o',str(work/'test')]
                result=subprocess.run(command,capture_output=True,text=True,timeout=60)
                self.assertEqual(result.returncode,0,result.stderr)
                run=subprocess.run([str(work/'test')],capture_output=True,text=True,timeout=15)
                self.assertEqual(run.returncode,0,run.stderr)
                self.assertEqual((state/'probe-spent-v1').read_bytes(),grant.read_bytes())


if __name__=='__main__':unittest.main(verbosity=2)
