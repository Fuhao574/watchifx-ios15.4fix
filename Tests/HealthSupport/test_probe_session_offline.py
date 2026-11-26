"""Actual private grant/receipt files and owned clock; no device/Health data."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
PROBE=HERE.parents[1]/'Modules/HealthSupport/QueryRouteProbe'
FAULTS=r'''
#include "ProbeSession.h"
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdarg.h>
#include <assert.h>
#include <string.h>
#include <stdio.h>
static int fault,writes,syncs;
static WFHSProbeClock now={"12345678-1234-1234-1234-123456789ABC",1000,50};
static int clockRead(WFHSProbeClock *c){*c=now;return 0;}
static ssize_t fixtureWrite(int fd,const void *data,size_t length) {
 ++writes;
 if(fault==1&&writes==1){errno=EINTR;return -1;}
 if(fault==2&&length>3)length=3;
 if(fault==3)return 0;
 if(fault==4){errno=ENOSPC;return -1;}
 ssize_t result=write(fd,data,length);
 if(fault==9)_exit(29); // crash after actual receipt write, before durability
 return result;
}
static int fixtureSync(int fd) {
 ++syncs;
 if((fault==5&&syncs==1)||(fault==7&&syncs==2)){errno=EIO;return -1;}
 int result=fsync(fd);if(fault==10&&syncs==2)_exit(30);return result;
}
static int fixtureFcntl(int fd,int command,...) {
 if(command==F_FULLFSYNC) {
  if(fault==6){errno=EIO;return -1;}
  return fcntl(fd,command);
 }
 assert(command==F_DUPFD_CLOEXEC);va_list args;va_start(args,command);int value=va_arg(args,int);va_end(args);
 return fcntl(fd,command,value);
}
static int fixtureClose(int fd) {
 struct stat st;int receipt=!fstat(fd,&st)&&S_ISREG(st.st_mode)&&(fcntl(fd,F_GETFL)&O_ACCMODE)==O_WRONLY;
 int result=close(fd);if(fault==8&&receipt){errno=EIO;return -1;}return result;
}
#define write(...) fixtureWrite(__VA_ARGS__)
#define fsync(...) fixtureSync(__VA_ARGS__)
#define fcntl(...) fixtureFcntl(__VA_ARGS__)
#define close(...) fixtureClose(__VA_ARGS__)
#include "ProbeSession.c"
#undef write
#undef fsync
#undef fcntl
#undef close
int main(int argc,char **argv) {
 assert(argc==2);int root=open(argv[1],O_RDONLY|O_DIRECTORY);assert(root>=0);
 for(fault=1;fault<=10;++fault) {
  writes=syncs=0;char name[24];snprintf(name,sizeof(name),"fault%d",fault);assert(!mkdirat(root,name,0700));
  int dir=openat(root,name,O_RDONLY|O_DIRECTORY);assert(dir>=0);unsigned char grant[96]={0};
  memcpy(grant,"WFHS-PROBE-G1\n",14);memcpy(grant+16,now.boot,37);
  uint64_t values[]={990,1080,90};for(unsigned v=0;v<3;++v)for(unsigned i=0;i<8;++i)grant[56+v*8+i]=(unsigned char)(values[v]>>(i*8));grant[80]=1;
  int fd=openat(dir,"probe-grant-v1",O_WRONLY|O_CREAT|O_EXCL,0600);assert(fd>=0&&write(fd,grant,96)==96);close(fd);
  if(fault>=9) {
   pid_t child=fork();assert(child>=0);
   if(!child){WFHSProbeSession state=WFHS_PROBE_SESSION_INITIALIZER;(void)WFHSProbeClaimSession(&state,dir,clockRead);_exit(99);}
   int status;assert(waitpid(child,&status,0)==child&&WIFEXITED(status)&&WEXITSTATUS(status)==(fault==9?29:30));
  } else {
   WFHSProbeSession state=WFHS_PROBE_SESSION_INITIALIZER;int success=WFHSProbeClaimSession(&state,dir,clockRead);
   assert(success==(fault<=2));
   if(!success) {
    assert(WFHSProbeSessionState(&state)==WFHSProbeSessionPersistenceFailed);
    WFHSProbeStopSession(&state);assert(WFHSProbeSessionState(&state)==WFHSProbeSessionPersistenceFailed);
   }
  }
  struct stat spent;assert(!fstatat(dir,"probe-spent-v1",&spent,AT_SYMLINK_NOFOLLOW));
  WFHSProbeSession next=WFHS_PROBE_SESSION_INITIALIZER;
  assert(!WFHSProbeClaimSession(&next,dir,clockRead)&&WFHSProbeSessionState(&next)==WFHSProbeSessionSpent);
  WFHSProbeStopSession(&next);assert(WFHSProbeSessionState(&next)==WFHSProbeSessionSpent);
  close(dir);
 }
 close(root);puts("PASS real receipt fault/crash seams retain spent; no repair/refund or installation");
}
'''
MAIN=r'''
#include "ProbeSession.h"
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
static WFHSProbeClock current={"12345678-1234-1234-1234-123456789ABC",1000,50};
static int readClock(WFHSProbeClock *clock){*clock=current;return 0;}
static void le(unsigned char *p,uint64_t value){for(unsigned i=0;i<8;++i)p[i]=(unsigned char)(value>>(i*8));}
static void grant(int dir) {
 unsigned char bytes[96]={0};memcpy(bytes,"WFHS-PROBE-G1\n",14);memcpy(bytes+16,current.boot,37);
 le(bytes+56,990);le(bytes+64,1080);le(bytes+72,90);bytes[80]=1;
 int fd=openat(dir,"probe-grant-v1",O_CREAT|O_EXCL|O_WRONLY,0600);assert(fd>=0&&write(fd,bytes,96)==96);close(fd);
}
static int subdir(int parent,const char *name) {assert(!mkdirat(parent,name,0700));int fd=openat(parent,name,O_RDONLY|O_DIRECTORY);assert(fd>=0);return fd;}
int main(int argc,char **argv) {
 assert(argc==2);int root=open(argv[1],O_RDONLY|O_DIRECTORY);assert(root>=0);
 int dir=subdir(root,"normal");grant(dir);
 WFHSProbeSession s=WFHS_PROBE_SESSION_INITIALIZER;
 assert(WFHSProbeClaimSession(&s,dir,readClock));
 struct stat st;assert(!fstatat(dir,"probe-spent-v1",&st,AT_SYMLINK_NOFOLLOW)&&st.st_size==96);
 assert(WFHSProbeSessionAllows(&s,readClock));
 assert(!WFHSProbeClaimSession(&s,dir,readClock));
 WFHSProbeSession next=WFHS_PROBE_SESSION_INITIALIZER;
 assert(!WFHSProbeClaimSession(&next,dir,readClock)&&WFHSProbeSessionState(&next)==WFHSProbeSessionSpent);
 current.wall=1010;current.monotonic=60;assert(WFHSProbeSessionAllows(&s,readClock));
 current.wall=1009;current.monotonic=61;assert(!WFHSProbeSessionAllows(&s,readClock)&&WFHSProbeSessionState(&s)==WFHSProbeSessionClockFailed);
 current.wall=1011;current.monotonic=62;assert(!WFHSProbeSessionAllows(&s,readClock));close(dir);
 WFHSProbeStopSession(&s);WFHSProbeFailSession(&s);assert(WFHSProbeSessionState(&s)==WFHSProbeSessionClockFailed);
 // Deadline uses claim's REMAINING 80 seconds; wall staying below deadline does
 // not grant a fresh90s if wall clock runs slowly relative to monotonic.
 current.wall=1000;current.monotonic=50;dir=subdir(root,"expiry");grant(dir);
 WFHSProbeSession exp=WFHS_PROBE_SESSION_INITIALIZER;assert(WFHSProbeClaimSession(&exp,dir,readClock));
 current.wall=1079;current.monotonic=130;assert(!WFHSProbeSessionAllows(&exp,readClock)&&WFHSProbeSessionState(&exp)==WFHSProbeSessionExpired);close(dir);
 WFHSProbeStopSession(&exp);assert(WFHSProbeSessionState(&exp)==WFHSProbeSessionExpired);
 for(unsigned scenario=0;scenario<10;++scenario) {
  current.wall=1000;current.monotonic=50;char name[32];snprintf(name,sizeof(name),"bad%u",scenario);dir=subdir(root,name);grant(dir);
  int fd=openat(dir,"probe-grant-v1",O_WRONLY);assert(fd>=0);
  if(scenario==0)assert(!fchmod(fd,0644));
  if(scenario==1)assert(!ftruncate(fd,95));
  if(scenario==2)assert(pwrite(fd,"X",1,0)==1);
  if(scenario==3)assert(pwrite(fd,"X",1,16)==1);
  if(scenario==4)current.wall=1080;
  if(scenario==5)current.wall=989;
  if(scenario==6)current.monotonic=NAN;
  if(scenario==7)assert(!fchmod(dir,0755));
  if(scenario==8)assert(!linkat(dir,"probe-grant-v1",dir,"extra-link",0));
  close(fd);
  if(scenario==9){assert(!unlinkat(dir,"probe-grant-v1",0));assert(!mkfifoat(dir,"probe-grant-v1",0600));}
  WFHSProbeSession bad=WFHS_PROBE_SESSION_INITIALIZER;assert(!WFHSProbeClaimSession(&bad,dir,readClock));
  WFHSProbeStopSession(&bad);assert(WFHSProbeSessionState(&bad)==WFHSProbeSessionRejected);
  assert(fstatat(dir,"probe-spent-v1",&st,AT_SYMLINK_NOFOLLOW));close(dir);
 }
 // Independent processes race the actual O_EXCL receipt. No sleeps/polling.
 current.wall=1000;current.monotonic=50;dir=subdir(root,"race");grant(dir);int barrier[2];assert(!pipe(barrier));pid_t children[2];
 for(unsigned i=0;i<2;++i) {
  children[i]=fork();assert(children[i]>=0);
  if(!children[i]) {close(barrier[1]);char c;assert(read(barrier[0],&c,1)==1);WFHSProbeSession local=WFHS_PROBE_SESSION_INITIALIZER;_exit(WFHSProbeClaimSession(&local,dir,readClock)?0:2);}
 }
 close(barrier[0]);assert(write(barrier[1],"xx",2)==2);close(barrier[1]);unsigned wins=0;
 for(unsigned i=0;i<2;++i){int status;assert(waitpid(children[i],&status,0)==children[i]&&WIFEXITED(status));if(WEXITSTATUS(status)==0)++wins;else assert(WEXITSTATUS(status)==2);}
 assert(wins==1);close(dir);
 dir=subdir(root,"protocol");grant(dir);WFHSProbeSession protocol=WFHS_PROBE_SESSION_INITIALIZER;
 assert(WFHSProbeClaimSession(&protocol,dir,readClock));WFHSProbeFailSession(&protocol);WFHSProbeStopSession(&protocol);
 assert(WFHSProbeSessionState(&protocol)==WFHSProbeSessionProtocolFailed);close(dir);
 // A stop before claim is terminal; no file creation, no refund APIs.
 dir=subdir(root,"stop");grant(dir);WFHSProbeSession stopped=WFHS_PROBE_SESSION_INITIALIZER;
 WFHSProbeStopSession(&stopped);assert(!WFHSProbeClaimSession(&stopped,dir,readClock));
 assert(fstatat(dir,"probe-spent-v1",&st,AT_SYMLINK_NOFOLLOW));close(dir);close(root);
 puts("PASS real one-shot receipt/durability-before-grant/process race/clock high-water/passive expiry/no device enable");
}
'''


class ProbeSessionTests(unittest.TestCase):
    def test_persistence_failure_and_crash_seams(self):
        with tempfile.TemporaryDirectory(prefix='probe-faults-',dir=HERE) as tmp:
            work=Path(tmp);(work/'main.c').write_text(FAULTS)
            for optimization in ('-O0','-O2'):
                state=work/optimization;state.mkdir(mode=0o700)
                result=subprocess.run(['xcrun','clang','-std=c11',optimization,'-Wall','-Wextra','-Werror',
                    '-fsanitize=address,undefined','-pthread','-I',str(PROBE),str(work/'main.c'),'-o',str(work/'test')],
                    capture_output=True,text=True,timeout=60)
                self.assertEqual(result.returncode,0,result.stderr)
                run=subprocess.run([str(work/'test'),str(state)],capture_output=True,text=True,timeout=15)
                self.assertEqual(run.returncode,0,run.stderr)

    def test_actual_files_and_process_race(self):
        with tempfile.TemporaryDirectory(prefix='probe-session-',dir=HERE) as tmp:
            work=Path(tmp);source=work/'main.c';source.write_text(MAIN)
            for optimization in ('-O0','-O2'):
                state=work/optimization;state.mkdir(mode=0o700)
                command=['xcrun','clang','-std=c11',optimization,'-Wall','-Wextra','-Werror','-fsanitize=address,undefined',
                         '-pthread','-I',str(PROBE),str(PROBE/'ProbeSession.c'),str(source),'-o',str(work/'test')]
                result=subprocess.run(command,capture_output=True,text=True,timeout=60)
                self.assertEqual(result.returncode,0,result.stderr)
                run=subprocess.run([str(work/'test'),str(state)],capture_output=True,text=True,timeout=15)
                self.assertEqual(run.returncode,0,run.stderr)


if __name__=='__main__':unittest.main(verbosity=2)
