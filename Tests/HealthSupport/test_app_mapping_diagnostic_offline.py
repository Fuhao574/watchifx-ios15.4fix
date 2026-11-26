"""Actual in-App diagnostic function with self-owned syscall fixtures, no device."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
DIAGNOSTIC = PROJECT / 'Modules/HealthSupport/AppDiagnostics'
MAIN = r'''
#import <Foundation/Foundation.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <assert.h>
#include <stdarg.h>
static int scenario,queries,opens,closes,pidQueries,a1Stats,baseStats;
const int SANDBOX_CHECK_NO_REPORT=0x40000000;
static int FixtureSystem(const char *name,void *data,size_t *length,void *newp,size_t newlen) {
 assert(!strcmp(name,"kern.osversion")&&!newp&&!newlen&&*length>=7);memcpy(data,"19E241",7);*length=7;return 0;
}
static int FixturePID(int pid,void *data,uint32_t length) {
 assert(pid==123&&length>=128);++pidQueries;
 if(scenario==1){errno=EPERM;return -1;}
 const char *value=(scenario==2||(scenario==5&&pidQueries>1))?"/wrong/host":"/System/Library/Frameworks/HealthKit.framework/healthd";
 strcpy(data,value);return (int)strlen(value);
}
static int FixtureOpen(const char *path,int flags,...) {
 ++opens;assert((!strcmp(path,"/fixed/a1.dylib")||!strcmp(path,"/fixed/base.dylib")||!strcmp(path,"/fixed/copy.dylib"))&&flags==(O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC));
 if(scenario==3||(scenario==7&&!strcmp(path,"/fixed/base.dylib"))||(scenario==13&&!strcmp(path,"/fixed/a1.dylib"))||(scenario==14&&!strcmp(path,"/fixed/copy.dylib"))){errno=EACCES;return -1;}
 return !strcmp(path,"/fixed/a1.dylib")?7:(!strcmp(path,"/fixed/base.dylib")?8:9);
}
static int FixtureFstat(int fd,struct stat *st) {
 assert(fd>=7&&fd<=9);memset(st,0,sizeof(*st));st->st_mode=S_IFREG|(fd==8?0755:0600);st->st_gid=fd==8?0:501;
 st->st_size=fd==8?240304:90928;st->st_uid=fd==8?0:501;st->st_dev=4;st->st_ino=fd+1;
 if(scenario==15&&fd==9)++st->st_uid;
 if(scenario==8&&fd==8){errno=EIO;return -1;}return 0;
}
static int FixtureStat(const char *path,struct stat *st) {
 BOOL base=strstr(path,"base")!=NULL;
 assert(!strcmp(path,"/fixed/a1.dylib")||!strcmp(path,"/fd/a1.dylib")||!strcmp(path,"/fixed/base.dylib")||!strcmp(path,"/fd/base.dylib")||!strcmp(path,"/fixed/copy.dylib")||!strcmp(path,"/fd/copy.dylib"));
 int result=FixtureFstat(base?8:(strstr(path,"copy")?9:7),st);int count=base?++baseStats:++a1Stats;
 if(base&&scenario==9)++st->st_ino;
 if(base&&scenario==10&&count>3)++st->st_ino;
 if(strstr(path,"copy")&&scenario==16)++st->st_ino;
 if(strstr(path,"copy")&&scenario==17&&queries>=18)st->st_mode=S_IFREG|0644;
 return result;
}
static int FixtureFcntl(int fd,int command,...) {
 assert((fd>=7&&fd<=9)&&command==F_GETPATH);
 if(scenario==11&&fd==8){errno=EPERM;return -1;}
 va_list args;va_start(args,command);char *value=va_arg(args,char *);va_end(args);strcpy(value,fd==7?"/fd/a1.dylib":(fd==8?"/fd/base.dylib":"/fd/copy.dylib"));return 0;
}
static char *FixtureRealpath(const char *path,char *value) {
 assert(!strcmp(path,"/fixed/a1.dylib")||!strcmp(path,"/fixed/base.dylib")||!strcmp(path,"/fixed/copy.dylib"));
 if(scenario==12&&strstr(path,"base")){errno=EACCES;return NULL;}strcpy(value,path);return value;
}
static int FixtureClose(int fd) {assert(fd>=7&&fd<=9);++closes;return 0;}
static int FixtureSandbox(pid_t pid,const char *operation,int filter,...) {
 assert(pid==123&&filter==(1|SANDBOX_CHECK_NO_REPORT));++queries;
 va_list args;va_start(args,filter);const char *path=va_arg(args,const char *);va_end(args);
 assert(!strcmp(path,"/fixed/a1.dylib")||!strcmp(path,"/fd/a1.dylib")||!strcmp(path,"/fixed/base.dylib")||!strcmp(path,"/fd/base.dylib")||!strcmp(path,"/fixed/copy.dylib")||!strcmp(path,"/fd/copy.dylib"));
 if(scenario==6){errno=EPERM;return -1;}
 return !strcmp(operation,"file-read-data")?0:((strstr(path,"base")||strstr(path,"copy"))&&scenario!=4?0:1);
}
#define sysctlbyname(...) FixtureSystem(__VA_ARGS__)
#define proc_pidpath(...) FixturePID(__VA_ARGS__)
#define open(...) FixtureOpen(__VA_ARGS__)
#define fstat(...) FixtureFstat(__VA_ARGS__)
#define stat(...) FixtureStat(__VA_ARGS__)
#define fcntl(...) FixtureFcntl(__VA_ARGS__)
#define realpath(...) FixtureRealpath(__VA_ARGS__)
#define close(...) FixtureClose(__VA_ARGS__)
#define sandbox_check(...) FixtureSandbox(__VA_ARGS__)
#include "FixedMappingDiagnostic.m"
int main(void) {
 @autoreleasepool {
   for(scenario=0;scenario<=17;++scenario) {
    queries=opens=closes=pidQueries=a1Stats=baseStats=0;
   NSDictionary *result=WFHSRunFixedMappingDiagnostic();assert(result);
   assert([result[@"receiveEnabled"] isEqual:@NO]&&[result[@"hooksInstalled"] isEqual:@NO]&&[result[@"healthSamplesRead"] isEqual:@NO]);
   if(scenario==0||scenario==4||scenario==6) {
     assert([result[@"status"] isEqual:scenario==6?@"unknown":@"observed"]&&queries==18&&opens==3&&closes==3);
    assert([result[@"policyQueriesComplete"] isEqual:scenario==6?@NO:@YES]);
     NSArray *files=result[@"files"];assert(files.count==3);
     NSArray *policy=files[0][@"policy"];assert(policy.count==3);
     assert([policy[0][@"mapObservation"] isEqual:scenario==6?@"query-failed":@"denied-query"]);
     NSArray *summary=result[@"comparison"];assert(summary.count==3);
     assert(([summary[1][@"mapResults"] isEqual:scenario==6?@[@(-1),@(-1),@(-1)]:(scenario==4?@[@1,@1,@1]:@[@0,@0,@0])]));
     assert([summary[2][@"mapResults"] isEqual:summary[1][@"mapResults"]]);
   } else {
    assert([result[@"status"] isEqual:@"unknown"]);
    if(scenario<=2)assert(opens==0&&queries==0);
     if(scenario==3)assert(closes==0&&queries==0&&opens==3);
     if(scenario==5)assert(queries==18&&closes==3);
     if(scenario==7)assert(queries==12&&closes==2);
     if(scenario>=8&&scenario<=12)assert(closes==3&&queries==(scenario==10?18:12));
     if(scenario==13){assert(closes==2&&queries==12);assert([result[@"files"][1][@"status"] isEqual:@"observed"]);}
     if(scenario==14)assert(closes==2&&queries==12);
     if(scenario==15)assert(closes==3&&queries==12);
     if(scenario==16)assert(closes==3&&queries==12);
     if(scenario==17)assert(closes==3&&queries==18);
   }
  }
  puts("PASS actual in-App diagnostic/permission unknown/no root child/fixed path-policy/raw returns/no log or write");
 }
}
'''


class AppMappingDiagnosticTests(unittest.TestCase):
    def test_own_syscall_fixtures(self):
        with tempfile.TemporaryDirectory(prefix='app-mapping-host-', dir=HERE) as temporary:
            work = Path(temporary)
            (work / 'FixedMappingDiagnosticPrivate.h').write_text(
                '#define WFHS_DIAGNOSTIC_PID 123\n#define WFHS_DIAGNOSTIC_SIZE 90928\n'
                '#define WFHS_DIAGNOSTIC_UID 501\n#define WFHS_DIAGNOSTIC_PATH "/fixed/a1.dylib"\n')
            with (work / 'FixedMappingDiagnosticPrivate.h').open('a') as header:
                header.write('#define WFHS_DIAGNOSTIC_DEVICE 4\n#define WFHS_DIAGNOSTIC_INODE 8\n'
                             '#define WFHS_BASE_PATH "/fixed/base.dylib"\n#define WFHS_BASE_SIZE 240304\n'
                             '#define WFHS_BASE_UID 0\n#define WFHS_BASE_DEVICE 4\n#define WFHS_BASE_INODE 9\n'
                             '#define WFHS_COPY_PATH "/fixed/copy.dylib"\n#define WFHS_COPY_SIZE 90928\n'
                             '#define WFHS_COPY_UID 501\n#define WFHS_COPY_DEVICE 4\n#define WFHS_COPY_INODE 10\n')
                header.write('#define WFHS_DIAGNOSTIC_GID 501\n#define WFHS_DIAGNOSTIC_MODE 0600\n'
                             '#define WFHS_BASE_GID 0\n#define WFHS_BASE_MODE 0755\n'
                             '#define WFHS_COPY_GID 501\n#define WFHS_COPY_MODE 0600\n')
            source, binary = work / 'main.m', work / 'diagnostic'
            source.write_text(MAIN)
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang', '-fobjc-arc', '-fobjc-arc-exceptions', optimization,
                        '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                        '-DWATCHFIX_HEALTH_DIAGNOSTICS=1', '-framework', 'Foundation',
                        '-I', str(work), '-I', str(DIAGNOSTIC), str(source), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('permission unknown/no root child', result.stdout)

    def test_default_build_excludes_diagnostic_entry(self):
        text = (PROJECT / 'App/Views/DebugViewController.swift').read_text()
        self.assertEqual(text.count('#if WATCHFIX_HEALTH_DIAGNOSTICS'), 2)
        self.assertIn('private static var healthMappingConsumed', text)
        self.assertIn('guard let self, !self.healthMappingRunning, !Self.healthMappingConsumed', text)
        implementation = (DIAGNOSTIC / 'FixedMappingDiagnostic.m').read_text()
        for forbidden in ('posix_spawn(', 'task_for_pid(', 'mach_vm_read(', 'dlopen(', 'mmap(',
                          'sandbox_extension_', 'NSLog(', 'write(', 'sqlite3_', 'HKHealthStore'):
            self.assertNotIn(forbidden, implementation)
        self.assertIn('#error "Fixed mapping diagnostic is only built by explicit diagnostics opt-in"', implementation)
        self.assertFalse((DIAGNOSTIC / 'Makefile').exists())
        self.assertFalse((DIAGNOSTIC / 'FixedMappingDiagnosticPrivate.h').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
