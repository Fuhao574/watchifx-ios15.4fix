"""Own scalar logger under real concurrent event calls, never OS/device logs."""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
PROBE=HERE.parents[1]/'Modules/HealthSupport/QueryRouteProbe'
MAIN=r'''
#include "QueryRouteProbe.h"
#include "ProbeReceipt.h"
#include <stdatomic.h>
#include <pthread.h>
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
static atomic_uint logged,seen,reads;
static unsigned mode;
int WFHSCopyQueryRouteProbeReportV3(void *buffer,uint32_t capacity) {
 assert(buffer&&capacity==112);atomic_fetch_add(&reads,1);
 if(mode==1)return -1;
 WFHSQueryRouteProbeReport r={0};r.schema=3;r.reportSize=sizeof(r);
 r.enumeratorInitializations=r.admittedEnumerations=r.rejectedEnumerations=UINT64_MAX;
 r.boundBuilders=r.observedCreates=r.protocolFailures=r.completedEnumerations=r.inFlightWrappers=UINT64_MAX;
 r.installed=r.enabled=r.installStatus=r.lifecycle=UINT32_MAX;memcpy(buffer,&r,sizeof(r));return 0;
}
uint32_t WFHSQueryRouteProbeSessionStateV1(void){return UINT32_MAX;}
void FixtureReceiptLog(const char *line) {
 assert(strlen(line)<512);assert(!strncmp(line,"WFHS_QROUTE_RECEIPT_V1 ",22));
 unsigned event=0;assert(sscanf(line,"WFHS_QROUTE_RECEIPT_V1 event=%u",&event)==1&&event>=1&&event<=4);
 assert(!(atomic_fetch_or(&seen,1u<<(event-1))&(1u<<(event-1))));
 atomic_fetch_add(&logged,1);assert(strstr(line,"receive=0 modified=0 samples=0"));
 // mode2 deliberately drops the record: no delivery/ACK and no retry.
}
static void *worker(void *unused) {
 (void)unused;
 for(unsigned i=0;i<100;++i)for(unsigned e=1;e<=4;++e)WFHSProbeEmitReceipt(e,INT32_MIN,1,1);
 return NULL;
}
int main(int argc,char **argv) {
 assert(argc==2);mode=(unsigned)atoi(argv[1]);
 WFHSProbeEmitReceipt(0,0,0,0);WFHSProbeEmitReceipt(5,0,0,0);assert(!atomic_load(&reads));
 pthread_t threads[8];for(unsigned i=0;i<8;++i)assert(!pthread_create(&threads[i],NULL,worker,NULL));
 for(unsigned i=0;i<8;++i)assert(!pthread_join(threads[i],NULL));
 assert(atomic_load(&reads)==4);
 assert(atomic_load(&logged)==(mode==1?0u:4u)&&atomic_load(&seen)==(mode==1?0u:15u));
 puts("PASS bounded scalar receipt length under maximal counters; four attempts under contention, no refunds");
}
'''


class ReceiptTests(unittest.TestCase):
    def test_scalar_budget_under_concurrent_calls(self):
        with tempfile.TemporaryDirectory(prefix='probe-receipts-',dir=HERE) as tmp:
            work=Path(tmp);(work/'main.c').write_text(MAIN);(work/'os').mkdir()
            (work/'os/log.h').write_text('#define OS_LOG_DEFAULT 0\nvoid FixtureReceiptLog(const char *line);\n#define os_log_error(log,format,line) FixtureReceiptLog(line)\n')
            for opt in ('-O0','-O2'):
                result=subprocess.run(['xcrun','clang','-std=c11',opt,'-Wall','-Wextra','-Werror','-pthread',
                    '-DWFHS_ROUTE_RECEIPT_LOG=1','-DWFHS_ROUTE_BOUNDED_SESSION=1','-fsanitize=address,undefined',
                    '-I',str(work),'-I',str(PROBE),str(PROBE/'ProbeReceipt.c'),str(work/'main.c'),'-o',str(work/'test')],
                    capture_output=True,text=True,timeout=60)
                self.assertEqual(result.returncode,0,result.stderr)
                for mode in range(3):
                    run=subprocess.run([str(work/'test'),str(mode)],capture_output=True,text=True,timeout=10)
                    self.assertEqual(run.returncode,0,run.stderr)

    def test_receipt_variant_is_explicit_bounded_unsigned(self):
        result=subprocess.run(['python3','-B',str(PROBE/'build_receipt_candidate.py')],capture_output=True,text=True,timeout=120)
        self.assertEqual(result.returncode,0,result.stderr)
        output=Path(next(l.split(': ',1)[1] for l in result.stdout.splitlines() if l.startswith('BUILT local unsigned')))
        manifest=json.loads((output/'build-local.json').read_text())
        self.assertTrue(manifest['boundedSession'] and manifest['receiptLogging'])
        self.assertEqual(manifest['maximumReceiptAttempts'],4)
        self.assertEqual(manifest['receiptMarker'],'WFHS_QROUTE_RECEIPT_V1')
        for key in ('installsOnLoad','safeDeviceLoaderImplemented','methodTableWriterOwnershipVerified','signed','packaged','deviceInstalled'):
            self.assertIs(manifest[key],False)
        for artifact in manifest['artifacts']:
            binary=output/artifact['file']
            self.assertIn(b'WFHS_QROUTE_RECEIPT_V1',binary.read_bytes())
            imports=subprocess.check_output(['xcrun','nm','-u',str(binary)],text=True)
            self.assertIn('__os_log_error_impl',imports)
            for forbidden in ('_task_for_pid','_task_threads','_thread_suspend','_thread_resume','_dlopen','_posix_spawn','_sqlite3'):
                self.assertNotIn(forbidden,imports)


if __name__=='__main__':unittest.main(verbosity=2)
