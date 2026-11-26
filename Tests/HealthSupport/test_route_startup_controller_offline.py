"""Fixed startup entry with owned directory and stub installer, no device load."""
from pathlib import Path
import ctypes
import json
import subprocess
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
PROBE=HERE.parents[1]/'Modules/HealthSupport/QueryRouteProbe'
MAIN=r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
static unsigned hostCalls,installCalls;
static int hostMatches=1;
static int mode,lastDirectory=-1;
static unsigned stops;
@interface PoolExitThrower : NSObject @end
@implementation PoolExitThrower
- (void)dealloc {@throw @"OwnedPoolExitException";}
@end
extern id objc_autorelease(id object __attribute__((ns_consumed))) __attribute__((ns_returns_not_retained));
int WFHSQueryRouteHostMatches(void){++hostCalls;return hostMatches;}
#include "StartupController.m"
int WFHSInstallQueryRouteProbeSessionV1(int directory) {
 struct stat st;assert(!fstat(directory,&st)&&S_ISDIR(st.st_mode));++installCalls;lastDirectory=directory;
  if(mode==3)@throw [NSException exceptionWithName:@"OwnedInstaller" reason:nil userInfo:nil];
  if(mode==4)@throw @"OwnedNonNSException";
  if(mode==5){__attribute__((objc_precise_lifetime)) id temporary=objc_autorelease([PoolExitThrower new]);(void)temporary;}
 return 7; // state must not reinterpret returned rejection as success.
}
void WFHSStopQueryRouteProbe(void) {++stops;if(mode==4)@throw @"OwnedStopException";}
int main(int argc,char **argv) {
 assert(argc==2);int scenario=argv[1][0]-'0';mode=scenario;
 if(scenario==1)hostMatches=0;
 if(scenario==2)assert(!chmod(WFHS_ROUTE_STARTUP_DIRECTORY,0755));
 WFHSRouteStartupEntry();
 unsigned expected=scenario==1?WFHSRouteStartupWrongHost:scenario==2?WFHSRouteStartupDirectoryRejected:scenario>=3?WFHSRouteStartupInstallerException:WFHSRouteStartupInstallerReturned;
 assert(WFHSQueryRouteStartupStateV1()==expected&&hostCalls==1&&installCalls==(scenario==0||scenario>=3));
 assert(stops==(scenario>=3));
 if(lastDirectory>=0)assert(fcntl(lastDirectory,F_GETFD)==-1); // finally closes on return AND exception
 WFHSRouteStartupEntry();assert(hostCalls==1&&installCalls==(scenario==0||scenario>=3));
 puts("PASS fixed startup host/directory gate/one attempt/installer rejection not success");
}
'''


class StartupControllerTests(unittest.TestCase):
    def test_fixed_controller_only_calls_once_after_host_and_directory(self):
        with tempfile.TemporaryDirectory(prefix='route-startup-',dir=HERE) as tmp:
            work=Path(tmp)
            # Test entry invoked explicitly to configure owned fixture first.
            source=(PROBE/'StartupController.m').read_text().replace('constructor,used,noinline','used,noinline')
            (work/'StartupController.m').write_text(source)
            (work/'main.m').write_text(MAIN)
            for opt in ('-O0','-O2'):
                for scenario in range(6):
                    state=work/(opt+str(scenario));state.mkdir(mode=0o700);st=state.stat()
                    (work/'QueryRouteStartupPrivate.h').write_text(
                        '#define WFHS_ROUTE_STARTUP_ACTIVATION_REVIEWED 1\n'
                        f'#define WFHS_ROUTE_STARTUP_DIRECTORY "{state}"\n'
                        f'#define WFHS_ROUTE_STARTUP_DEVICE {st.st_dev}ULL\n'
                        f'#define WFHS_ROUTE_STARTUP_INODE {st.st_ino}ULL\n')
                    result=subprocess.run(['xcrun','clang','-fobjc-arc','-fobjc-arc-exceptions','-framework','Foundation',opt,'-Wall','-Wextra','-Werror',
                        '-DWFHS_ROUTE_STARTUP_CONTROLLER=1','-DWFHS_ROUTE_BOUNDED_SESSION=1',
                        '-DWFHS_ROUTE_STARTUP_PRIVATE_CONFIG=1','-fsanitize=address,undefined',
                        '-I',str(work),'-I',str(PROBE),str(work/'main.m'),'-o',str(work/'test')],
                        capture_output=True,text=True,timeout=60)
                    self.assertEqual(result.returncode,0,result.stderr)
                    run=subprocess.run([str(work/'test'),str(scenario)],capture_output=True,text=True,timeout=10)
                    self.assertEqual(run.returncode,0,run.stderr)

    def test_default_constructor_never_calls_host_or_installer(self):
        with tempfile.TemporaryDirectory(prefix='startup-disabled-',dir=HERE) as tmp:
            binary=Path(tmp)/'disabled.dylib'
            result=subprocess.run(['xcrun','clang','-dynamiclib','-fobjc-arc','-fobjc-arc-exceptions','-framework','Foundation','-O2','-Wall','-Wextra','-Werror',
                '-DWFHS_ROUTE_STARTUP_CONTROLLER=1','-DWFHS_ROUTE_BOUNDED_SESSION=1',
                str(PROBE/'StartupController.m'),'-o',str(binary)],capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stderr)
            imports=subprocess.check_output(['xcrun','nm','-u',str(binary)],text=True)
            for symbol in ('_WFHSInstallQueryRouteProbeSessionV1','_WFHSQueryRouteHostMatches','_open','_fstat'):
                self.assertNotIn(symbol,imports)
            library=ctypes.CDLL(str(binary));getter=library.WFHSQueryRouteStartupStateV1
            getter.restype=ctypes.c_uint32;getter.argtypes=[]
            self.assertEqual(getter(),1)

    def test_integrated_startup_build_remains_disabled(self):
        result=subprocess.run(['python3','-B',str(PROBE/'build_startup_disabled_candidate.py')],capture_output=True,text=True,timeout=120)
        self.assertEqual(result.returncode,0,result.stderr)
        output=Path(next(l.split(': ',1)[1] for l in result.stdout.splitlines() if l.startswith('BUILT local unsigned')))
        manifest=json.loads((output/'build-local.json').read_text())
        self.assertTrue(manifest['startupControllerImplemented'])
        for key in ('startupActivationEnabled','startupConstructorAttemptsInstallation','filterIncluded','safeDeviceLoaderImplemented','methodTableWriterOwnershipVerified','deviceInstalled'):
            self.assertIs(manifest[key],False)
        for artifact in manifest['artifacts']:
            symbols=subprocess.check_output(['xcrun','nm','-gU',str(output/artifact['file'])],text=True)
            self.assertIn('_WFHSQueryRouteStartupStateV1',symbols)


if __name__=='__main__':unittest.main(verbosity=2)
