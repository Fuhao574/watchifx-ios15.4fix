"""Install actual query-boundary replacements on OWN classes only, no device.

Production host/method/caller guards are never relaxed in shipped source.
Only the test translation unit replaces callsite attribution for owned methods.
"""
from pathlib import Path
import json
import re
import struct
import ctypes
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
MODULE = PROJECT / 'Modules/HealthSupport'
PROBE = MODULE / 'QueryRouteProbe'
ADAPTER = MODULE / 'Adapters'

MAIN = r'''
#include <assert.h>
static BOOL fixtureCaller=YES;
static unsigned replacementCalls,conflictAt;
static BOOL installationInterleave;
static unsigned stopAtReplacement;
static unsigned driftAfterReplacement;
static Method driftMethod;
static IMP conflictIMP;
static IMP FixtureSetImplementation(Method method,IMP replacement);
static void FixtureAfterReplacement(void);
'''
INSTALL_FIXTURES = r'''
static IMP FixtureSetImplementation(Method method,IMP replacement) {
 ++replacementCalls;
 if(conflictAt&&replacementCalls==conflictAt)method_setImplementation(method,conflictIMP);
 IMP old=method_setImplementation(method,replacement);
 if(installationInterleave)FixtureAfterReplacement();
 if(stopAtReplacement&&replacementCalls==stopAtReplacement)WFHSStopQueryRouteProbe();
 if(driftAfterReplacement&&replacementCalls==driftAfterReplacement)method_setImplementation(driftMethod,conflictIMP);
 return old;
}
'''
TEST = r'''
// Test-only convenience, never exported by the production dylib.
static WFHSQueryRouteProbeReport WFHSReadQueryRouteProbeReport(void) {
 WFHSQueryRouteProbeReport r={0};assert(!WFHSCopyQueryRouteProbeReportV3(&r,sizeof(r)));return r;
}
@interface ThrowingProbeTable : NSObject
- (id)objectForKey:(id)key;
@end
@implementation ThrowingProbeTable
- (id)objectForKey:(id)key {(void)key;@throw [NSException exceptionWithName:@"OwnedRegistryFailure" reason:nil userInfo:nil];}
@end
@interface FixtureProbeDay : NSObject
- (id)initWithMorningIndex:(int64_t)index weekday:(NSUInteger)weekday calendarCache:(id)cache;
- (id)createDaySummary;
@end
@interface FixtureProbeEnumerator : NSObject
@property(nonatomic,strong) id profile,cache;
- (id)initWithProfile:(id)profile calendarCache:(id)cache morningIndexRange:(WFHSProbeRange)range ascending:(BOOL)a requireSleepAnalysis:(BOOL)r onlySleepAnalysis:(BOOL)o debugIdentifier:(id)d;
- (BOOL)enumerateWithError:(NSError **)error handler:(WFHSProbeHandler)handler;
@end
static id expectedProfile,expectedCache,expectedDebug,summaryValue;
static WFHSProbeRange expectedRange={10,2};
static unsigned enumInitCalls,dayInitCalls,enumCalls,createCalls;
static NSException *exceptionValue;
static NSError *errorValue;
static BOOL throwOriginal,nestOriginal,stopInsideOriginal;
static void *StopProbeOnOwnedThread(void *unused) {(void)unused;WFHSStopQueryRouteProbe();return NULL;}
static id nestedEnumerator;
static unsigned initMode,dayInitMode;
static id SameABICreateConflict(id self,SEL cmd) {(void)self;(void)cmd;return summaryValue;}
@implementation FixtureProbeDay
- (id)initWithMorningIndex:(int64_t)index weekday:(NSUInteger)weekday calendarCache:(id)cache {
 assert(index==10&&weekday==3&&cache==expectedCache);++dayInitCalls;
 if(dayInitMode==1)return nil;
 if(dayInitMode==2)return class_createInstance(FixtureProbeDay.class,0);
 if(dayInitMode==3)@throw exceptionValue;
 return [super init];
}
- (id)createDaySummary {
 ++createCalls;
  if(!installationInterleave)assert(WFHSReadQueryRouteProbeReport().inFlightWrappers>=1);
 if(stopInsideOriginal) {
  assert(WFHSReadQueryRouteProbeReport().inFlightWrappers>=2);
  WFHSStopQueryRouteProbe();
  WFHSQueryRouteProbeReport state=WFHSReadQueryRouteProbeReport();
  assert(state.lifecycle==WFHSRouteStopped&&state.stopRequested&&!state.enabled&&state.inFlightWrappers>=2);
 }
 if(throwOriginal)@throw exceptionValue;return summaryValue;
}
@end
@implementation FixtureProbeEnumerator
- (id)initWithProfile:(id)profile calendarCache:(id)cache morningIndexRange:(WFHSProbeRange)range ascending:(BOOL)a requireSleepAnalysis:(BOOL)r onlySleepAnalysis:(BOOL)o debugIdentifier:(id)d {
 assert(profile==expectedProfile&&cache==expectedCache&&d==expectedDebug&&range.start==expectedRange.start&&range.duration==2&&a&&!r&&o);
 if(initMode==1)return nil;
 if(initMode==2) {
  FixtureProbeEnumerator *other=class_createInstance(FixtureProbeEnumerator.class,0);
  other.profile=profile;other.cache=cache;return other;
 }
 if(initMode==3)@throw exceptionValue;
 ++enumInitCalls;if((self=[super init])){self.profile=profile;self.cache=cache;}return self;
}
- (BOOL)enumerateWithError:(NSError **)error handler:(WFHSProbeHandler)handler {
 if(nestOriginal) {
  nestOriginal=NO;
  [nestedEnumerator enumerateWithError:error handler:handler];
 }
 ++enumCalls;id day=[[FixtureProbeDay alloc]initWithMorningIndex:10 weekday:3 calendarCache:self.cache];
 id summary=[day createDaySummary];BOOL stop=NO;handler(summary,&stop);assert(stop);
 if(error)*error=errorValue;return NO;
}
@end
static unsigned installationCallbacks;
static void *FixtureQueryDuringInstall(void *unused) {
 (void)unused;
 @autoreleasepool {
  id e=[[FixtureProbeEnumerator alloc]initWithProfile:expectedProfile calendarCache:expectedCache morningIndexRange:expectedRange ascending:YES requireSleepAnalysis:NO onlySleepAnalysis:YES debugIdentifier:expectedDebug];
  NSError *error=nil;__block unsigned deliveries=0;
  assert(![e enumerateWithError:&error handler:^(id s,BOOL *stop){assert(s==summaryValue);++deliveries;*stop=YES;}]);
  assert(error==errorValue&&deliveries==1);
  return NULL;
 }
}
static void FixtureAfterReplacement(void) {
 assert(atomic_load_explicit(&originalsReady,memory_order_acquire));
 assert(!atomic_load(&observationEnabled));
 for(unsigned i=0;i<4;++i)assert(originals[i]);
 // Reenter synchronously before the mutation returns old IMP, then exercise
 // another query thread. No polling or spinning, each native callback finishes.
 FixtureQueryDuringInstall(NULL);
 pthread_t thread;assert(!pthread_create(&thread,NULL,FixtureQueryDuringInstall,NULL));
 assert(!pthread_join(thread,NULL));++installationCallbacks;
 assert(!atomic_load(&initializedCount)&&!atomic_load(&enumerationCount)&&!atomic_load(&builderCount)&&!atomic_load(&createCount));
 assert(!atomic_load(&inFlightWrappers));
}
int main(void) {
 @autoreleasepool {
  unsigned char bytes[WFHSQueryRouteReportV3Size+16],unchanged[sizeof(bytes)];
  memset(bytes,0xa5,sizeof(bytes));memcpy(unchanged,bytes,sizeof(bytes));
  assert(WFHSCopyQueryRouteProbeReportV3(NULL,sizeof(bytes))==-1);
  for(uint32_t size=0;size<WFHSQueryRouteReportV3Size;++size) {
   assert(WFHSCopyQueryRouteProbeReportV3(bytes,size)==-1&&!memcmp(bytes,unchanged,sizeof(bytes)));
  }
  assert(!WFHSCopyQueryRouteProbeReportV3(bytes,sizeof(bytes)));
  assert(!memcmp(bytes+WFHSQueryRouteReportV3Size,unchanged+WFHSQueryRouteReportV3Size,16));
  // memcpy accepts byte-aligned caller storage; no struct-pointer alignment cast.
  assert(!WFHSCopyQueryRouteProbeReportV3(bytes+1,WFHSQueryRouteReportV3Size));
  expectedProfile=[NSObject new];expectedCache=[NSObject new];expectedDebug=[NSObject new];summaryValue=[NSObject new];
  errorValue=[NSError errorWithDomain:@"OriginalFixture" code:42 userInfo:nil];
  exceptionValue=[NSException exceptionWithName:@"Original" reason:nil userInfo:nil];
  assert(WFHSReadQueryRouteProbeReport().lifecycle==WFHSRouteUninstalled);
  // Stop before installation is terminal; no caller preference can reopen it.
  WFHSStopQueryRouteProbe();assert(!WFHSProbeBeginInstall());
  assert(WFHSReadQueryRouteProbeReport().lifecycle==WFHSRouteStopped);
  // Reset ONLY self-owned test state for independent lifecycle scenarios.
  atomic_store(&stopRequested,false);atomic_store(&installAttempted,false);atomic_store(&lifecycle,WFHSRouteUninstalled);
  assert(WFHSProbeBeginInstall());assert(!WFHSProbeBeginInstall());
  pthread_t stopper;assert(!pthread_create(&stopper,NULL,StopProbeOnOwnedThread,NULL));
  assert(!pthread_join(stopper,NULL));WFHSProbePublishInstall(0);
  assert(!WFHSReadQueryRouteProbeReport().enabled&&WFHSReadQueryRouteProbeReport().lifecycle==WFHSRouteStopped);
  atomic_store(&stopRequested,false);atomic_store(&installAttempted,false);atomic_store(&lifecycle,WFHSRouteUninstalled);
  WFHSProbePublishInstall(4);assert(WFHSReadQueryRouteProbeReport().lifecycle==WFHSRouteRejected);
  atomic_store(&lifecycle,WFHSRouteUninstalled);
  Class __unsafe_unretained classes[]={FixtureProbeEnumerator.class,FixtureProbeEnumerator.class,FixtureProbeDay.class,FixtureProbeDay.class};
  SEL names[]={@selector(initWithProfile:calendarCache:morningIndexRange:ascending:requireSleepAnalysis:onlySleepAnalysis:debugIdentifier:),@selector(enumerateWithError:handler:),@selector(initWithMorningIndex:weekday:calendarCache:),@selector(createDaySummary)};
  IMP expected[4];for(unsigned i=0;i<4;++i)expected[i]=method_getImplementation(class_getInstanceMethod(classes[i],names[i]));
  for(unsigned bad=0;bad<4;++bad) {
   IMP wrong[4];for(unsigned i=0;i<4;++i)wrong[i]=expected[i];wrong[bad]=expected[(bad+1)%4];
   replacementCalls=0;assert(WFHSProbeInstallPrepared(classes,names,wrong)==4&&replacementCalls==0);
   for(unsigned i=0;i<4;++i)assert(method_getImplementation(class_getInstanceMethod(classes[i],names[i]))==expected[i]);
  }
   // Deliberate violation of writer ownership at exchange time. Detect it, never
   // rollback/rewrite while potential callers could already reference wrappers.
   // This does NOT prove preservation of the racing third-party chain.
   for(unsigned bad=0;bad<4;++bad) {
   conflictAt=bad+1;replacementCalls=0;conflictIMP=expected[(bad+1)%4];
   assert(WFHSProbeInstallPrepared(classes,names,expected)==5);
   assert(!atomic_load(&observationEnabled));
    for(unsigned i=0;i<4;++i)assert(method_getImplementation(class_getInstanceMethod(classes[i],names[i]))==(i<=bad?WFHSProbeReplacement(i):expected[i]));
    assert(WFHSProbeInstallPrepared(classes,names,expected)==8);
    // ONLY test-owned classes, with no active calls, are restored to establish
    // the next independent fixture scenario. Production never does this reset.
    for(unsigned i=0;i<4;++i)method_setImplementation(class_getInstanceMethod(classes[i],names[i]),expected[i]);
    atomic_store(&originalsReady,false);
   }
   conflictAt=0;
   // Drift of a not-yet-installed suffix is caught BEFORE another mutation;
   // drift of an installed prefix at the final seam prevents observation.
   for(unsigned at=1;at<=4;++at) {
    driftAfterReplacement=at;replacementCalls=0;
    driftMethod=class_getInstanceMethod(classes[3],names[3]);conflictIMP=(IMP)SameABICreateConflict;
    assert(WFHSProbeInstallPrepared(classes,names,expected)==5);
    assert(replacementCalls==at&&!atomic_load(&observationEnabled));
    assert(method_getImplementation(driftMethod)==conflictIMP);
    for(unsigned i=0;i<3;++i)assert(method_getImplementation(class_getInstanceMethod(classes[i],names[i]))==(i<at?WFHSProbeReplacement(i):expected[i]));
    assert(WFHSProbeInstallPrepared(classes,names,expected)==8);
    for(unsigned i=0;i<4;++i)method_setImplementation(class_getInstanceMethod(classes[i],names[i]),expected[i]);
    atomic_store(&originalsReady,false);
   }
   driftAfterReplacement=0;
   // Stop after an actual partial install: no retry/rollback, originals remain
   // published and the surviving hooks are pass-through through the full query.
   stopAtReplacement=2;replacementCalls=0;
   assert(WFHSProbeInstallPrepared(classes,names,expected)==7);
   WFHSProbePublishInstall(7);
   assert(!atomic_load(&observationEnabled)&&atomic_load(&stopRequested));
   assert(replacementCalls==2&&WFHSProbeInstallPrepared(classes,names,expected)==8);
   installationInterleave=YES;FixtureQueryDuringInstall(NULL);installationInterleave=NO;
   for(unsigned i=0;i<4;++i)assert(method_getImplementation(class_getInstanceMethod(classes[i],names[i]))==(i<2?WFHSProbeReplacement(i):expected[i]));
   for(unsigned i=0;i<4;++i)method_setImplementation(class_getInstanceMethod(classes[i],names[i]),expected[i]);
   atomic_store(&originalsReady,false);atomic_store(&stopRequested,false);atomic_store(&lifecycle,WFHSRouteUninstalled);
   stopAtReplacement=0;replacementCalls=0;enumInitCalls=dayInitCalls=enumCalls=createCalls=0;
   installationInterleave=YES;
   assert(WFHSProbeInstallPrepared(classes,names,expected)==0);
   installationInterleave=NO;
   assert(installationCallbacks==4&&enumCalls==8&&createCalls==8);
   enumInitCalls=dayInitCalls=enumCalls=createCalls=0;
   assert(WFHSProbeInstallPrepared(classes,names,expected)==8);
  WFHSProbePublishInstall(0);
  FixtureProbeEnumerator *enumerator=[[FixtureProbeEnumerator alloc]initWithProfile:expectedProfile calendarCache:expectedCache morningIndexRange:expectedRange ascending:YES requireSleepAnalysis:NO onlySleepAnalysis:YES debugIdentifier:expectedDebug];
  __block unsigned deliveries=0;NSError *error=nil;
  WFHSProbeHandler handler=^(id summary,BOOL *stop){assert(summary==summaryValue&&stop);++deliveries;*stop=YES;};
  assert(![enumerator enumerateWithError:&error handler:handler]&&error==errorValue&&deliveries==1);
  WFHSQueryRouteProbeReport report=WFHSReadQueryRouteProbeReport();
  assert(report.enumeratorInitializations==1&&report.admittedEnumerations==1&&report.boundBuilders==1&&report.observedCreates==1&&report.completedEnumerations==1);
  assert(!report.receiveEnabled&&!report.summariesModified&&!report.healthSamplesRead&&!report.protocolFailures);
  assert(report.schema==3&&report.reportSize==sizeof(report)&&report.lifecycle==WFHSRouteObserving&&!report.inFlightWrappers);
  // Same enumerator's later use is pass-through, never stale builder attribution.
  fixtureCaller=NO; // excluded original caller path, no factory attribution
  assert(![enumerator enumerateWithError:&error handler:handler]);
  fixtureCaller=YES;
  report=WFHSReadQueryRouteProbeReport();assert(report.admittedEnumerations==1&&report.rejectedEnumerations==1);
  // Caller rejection keeps exact original return/error/handler semantics.
  fixtureCaller=NO;
  id unknown=[[FixtureProbeEnumerator alloc]initWithProfile:expectedProfile calendarCache:expectedCache morningIndexRange:expectedRange ascending:YES requireSleepAnalysis:NO onlySleepAnalysis:YES debugIdentifier:expectedDebug];
  assert(![unknown enumerateWithError:&error handler:handler]&&error==errorValue);
  fixtureCaller=YES;
  // Original exception identity survives cleanup and attribution cannot leak.
  id throwing=[[FixtureProbeEnumerator alloc]initWithProfile:expectedProfile calendarCache:expectedCache morningIndexRange:expectedRange ascending:YES requireSleepAnalysis:NO onlySleepAnalysis:YES debugIdentifier:expectedDebug];
  throwOriginal=YES;BOOL caught=NO;
  @try{[throwing enumerateWithError:&error handler:handler];}@catch(NSException *e){caught=e==exceptionValue;}
  assert(caught);throwOriginal=NO;
  assert(!WFHSReadQueryRouteProbeReport().inFlightWrappers);
  report=WFHSReadQueryRouteProbeReport();assert(report.completedEnumerations==2);
  WFHSStopQueryRouteProbe();unsigned before=createCalls;
  assert(![enumerator enumerateWithError:&error handler:handler]&&createCalls==before+1);
  assert(!WFHSReadQueryRouteProbeReport().enabled);
  assert(enumInitCalls==3&&enumCalls==5&&dayInitCalls==5&&createCalls==5);
  // init-family ownership remains consumed-self/+1-result, including nil and
  // replacement returns. No stale allocated-self is retained by passthrough.
  __weak id weakAllocated,weakReturned;
  @autoreleasepool {
   initMode=1;
   id allocated=[FixtureProbeEnumerator alloc];weakAllocated=allocated;
   id value=[allocated initWithProfile:expectedProfile calendarCache:expectedCache morningIndexRange:expectedRange ascending:YES requireSleepAnalysis:NO onlySleepAnalysis:YES debugIdentifier:expectedDebug];
   assert(!value);allocated=nil;
  }
  assert(!weakAllocated);
  @autoreleasepool {
   initMode=2;
   id allocated=[FixtureProbeEnumerator alloc];weakAllocated=allocated;
   id value=[allocated initWithProfile:expectedProfile calendarCache:expectedCache morningIndexRange:expectedRange ascending:YES requireSleepAnalysis:NO onlySleepAnalysis:YES debugIdentifier:expectedDebug];
   assert(value&&value!=allocated);weakReturned=value;allocated=nil;value=nil;
  }
  assert(!weakAllocated&&!weakReturned);initMode=0;
  for(unsigned kind=0;kind<2;++kind)for(unsigned mode=0;mode<4;++mode) {
   __weak id allocatedWeak,returnedWeak;
   __strong id retained=nil;
   @autoreleasepool {
    initMode=kind==0?mode:0;dayInitMode=kind==1?mode:0;
    id allocated=kind==0?[FixtureProbeEnumerator alloc]:[FixtureProbeDay alloc];allocatedWeak=allocated;
    caught=NO;
    @try {
     retained=kind==0?[allocated initWithProfile:expectedProfile calendarCache:expectedCache morningIndexRange:expectedRange ascending:YES requireSleepAnalysis:NO onlySleepAnalysis:YES debugIdentifier:expectedDebug]:
        [allocated initWithMorningIndex:10 weekday:3 calendarCache:expectedCache];
    } @catch(NSException *e){caught=e==exceptionValue;}
    assert(caught==(mode==3));
    if(mode==1||mode==3)assert(!retained);
    else {assert(retained);returnedWeak=retained;if(mode==2)assert(retained!=allocated);}
    allocated=nil;
   }
   if(mode==1||mode==2||mode==3)assert(!allocatedWeak);
   if(mode==0||mode==2)assert(returnedWeak==retained);
   retained=nil;
   @autoreleasepool{};
   assert(!allocatedWeak&&!returnedWeak);
  }
  initMode=dayInitMode=0;
  // A rejected inner enumeration still has valid factory callsites. It must
  // disable attribution before its day can be mistaken for the outer query.
  atomic_store(&observationEnabled,true);fixtureCaller=YES;
  id outer=[[FixtureProbeEnumerator alloc]initWithProfile:expectedProfile calendarCache:expectedCache morningIndexRange:expectedRange ascending:YES requireSleepAnalysis:NO onlySleepAnalysis:YES debugIdentifier:expectedDebug];
  fixtureCaller=NO;
  nestedEnumerator=[[FixtureProbeEnumerator alloc]initWithProfile:expectedProfile calendarCache:expectedCache morningIndexRange:expectedRange ascending:YES requireSleepAnalysis:NO onlySleepAnalysis:YES debugIdentifier:expectedDebug];
  fixtureCaller=YES;nestOriginal=YES;
  report=WFHSReadQueryRouteProbeReport();uint64_t oldBuilders=report.boundBuilders,oldCreates=report.observedCreates,oldFailures=report.protocolFailures;
  assert(![outer enumerateWithError:&error handler:handler]&&error==errorValue);
  report=WFHSReadQueryRouteProbeReport();
  assert(!report.enabled&&report.boundBuilders==oldBuilders&&report.observedCreates==oldCreates&&report.protocolFailures==oldFailures+1);
  nestedEnumerator=nil;
  // Candidate registry exceptions disable observation, while native init still
  // returns the very object created by original; stop remains pass-through.
  NSMapTable *saved=enumerators;
  enumerators=(NSMapTable *)(id)[ThrowingProbeTable new];atomic_store(&observationEnabled,true);
  report=WFHSReadQueryRouteProbeReport();oldFailures=report.protocolFailures;
  id unobserved=[[FixtureProbeEnumerator alloc]initWithProfile:expectedProfile calendarCache:expectedCache morningIndexRange:expectedRange ascending:YES requireSleepAnalysis:NO onlySleepAnalysis:YES debugIdentifier:expectedDebug];
  assert(unobserved&&!WFHSReadQueryRouteProbeReport().enabled);
  assert(WFHSReadQueryRouteProbeReport().protocolFailures==oldFailures+1);
  enumerators=saved;
  assert(!WFHSReadQueryRouteProbeReport().inFlightWrappers);
  // Stop inside a live native call reports draining scopes without blocking it;
  // after it returns the count reaches zero, but method pointers stay installed.
  atomic_store(&stopRequested,false);atomic_store(&observationEnabled,true);
  id draining=[[FixtureProbeEnumerator alloc]initWithProfile:expectedProfile calendarCache:expectedCache morningIndexRange:expectedRange ascending:YES requireSleepAnalysis:NO onlySleepAnalysis:YES debugIdentifier:expectedDebug];
  stopInsideOriginal=YES;
  assert(![draining enumerateWithError:&error handler:handler]&&error==errorValue);
  stopInsideOriginal=NO;report=WFHSReadQueryRouteProbeReport();
  assert(report.lifecycle==WFHSRouteStopped&&!report.enabled&&!report.inFlightWrappers);
  for(unsigned i=0;i<4;++i)assert(method_getImplementation(class_getInstanceMethod(classes[i],names[i]))==WFHSProbeReplacement(i));
  // Test process only: restore OWN method table. Production API never unloads.
  for(unsigned i=0;i<4;++i)method_setImplementation(class_getInstanceMethod(classes[i],names[i]),expected[i]);
  puts("PASS actual method replacements on owned query classes/exact arguments-originals/error-handler-stop-exception/pass-through stop/no samples");
 }
}
'''


class QueryRouteProbeTests(unittest.TestCase):
    def test_bounded_build_cannot_bypass_claim(self):
        result=subprocess.run(['python3','-B',str(PROBE/'build_bounded_candidate.py')],capture_output=True,text=True,timeout=120)
        self.assertEqual(result.returncode,0,result.stderr)
        output=Path(next(line.split(': ',1)[1] for line in result.stdout.splitlines() if line.startswith('BUILT local unsigned')))
        manifest=json.loads((output/'build-local.json').read_text())
        self.assertTrue(manifest['boundedSession'])
        self.assertTrue(manifest['sessionClaimRequired'])
        self.assertFalse(manifest['installsOnLoad'])
        self.assertFalse(manifest['methodTableWriterOwnershipVerified'])
        for artifact in manifest['artifacts']:
            binary=output/artifact['file']
            symbols=subprocess.check_output(['xcrun','nm','-gU',str(binary)],text=True)
            exports=set(re.findall(r'\S+$',symbols,re.M))
            self.assertEqual(exports,{'_WFHSInstallQueryRouteProbeSessionV1','_WFHSQueryRouteProbeSessionStateV1','_WFHSStopQueryRouteProbe','_WFHSCopyQueryRouteProbeReportV3'})
            self.assertNotIn('_WFHSInstallQueryRouteProbe\n',symbols)

    def test_dormant_constructor_only_sets_own_state(self):
        text=(PROBE/'DormantBootstrap.c').read_text()
        for forbidden in ('WFHSInstallQueryRouteProbe','pthread_','dispatch_','dlopen','objc_','open(','write(','constructor)) static void WFHSProbe'):
            self.assertNotIn(forbidden,text)
        with tempfile.TemporaryDirectory(prefix='route-dormant-',dir=HERE) as temp:
            binary=Path(temp)/'dormant.dylib'
            command=['xcrun','clang','-dynamiclib','-O2','-std=c11','-Wall','-Wextra','-Werror',
                     '-DWFHS_ROUTE_DORMANT_BOOTSTRAP=1',str(PROBE/'DormantBootstrap.c'),'-o',str(binary)]
            result=subprocess.run(command,capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stderr)
            # Executes OUR scalar-only macOS bootstrap, not iOS output or Apple payload.
            library=ctypes.CDLL(str(binary));getter=library.WFHSRouteDormantBootstrapLoaded
            getter.argtypes=[];getter.restype=ctypes.c_uint32
            self.assertEqual(getter(),1)
            self.assertEqual(getter(),1)

    def test_explicit_dormant_build_is_not_auto_installation(self):
        result=subprocess.run(['python3','-B',str(PROBE/'build_dormant_candidate.py')],capture_output=True,text=True,timeout=120)
        self.assertEqual(result.returncode,0,result.stderr)
        output=Path(next(line.split(': ',1)[1] for line in result.stdout.splitlines() if line.startswith('BUILT local unsigned')))
        manifest=json.loads((output/'build-local.json').read_text())
        self.assertTrue(manifest['dormantBootstrap'])
        self.assertTrue(manifest['constructorOnlyMarksLoaded'])
        for key in ('installsOnLoad','installationControllerImplemented','safeDeviceLoaderImplemented','signed','packaged','deviceInstalled'):
            self.assertIs(manifest[key],False)
        for artifact in manifest['artifacts']:
            binary=output/artifact['file']
            data=binary.read_bytes();header=struct.unpack_from('<8I',data);pos=32;initializers=[]
            for _ in range(header[4]):
                cmd,size=struct.unpack_from('<II',data,pos)
                if cmd==0x19:
                    for i in range(struct.unpack_from('<I',data,pos+64)[0]):
                        section=pos+72+80*i
                        name=data[section:section+16].split(b'\0')[0]
                        if name in (b'__mod_init_func',b'__init_offsets'):
                            initializers.append(struct.unpack_from('<Q',data,section+40)[0])
                pos+=size
            self.assertTrue(initializers,'optimized dormant artifact must retain an init entry')
            disassembly=subprocess.check_output(['xcrun','otool','-tvV',str(binary)],text=True)
            entry=disassembly.split('_WFHSRouteDormantEntry:',1)[1].split('\n_',1)[0]
            getter=disassembly.split('_WFHSRouteDormantBootstrapLoaded:',1)[1].split('\n_',1)[0]
            self.assertRegex(entry,r'\b(?:str|stlr)\b')
            self.assertRegex(getter,r'\b(?:ldr|ldar|ldapr)\b')
            imports=subprocess.check_output(['xcrun','nm','-u',str(binary)],text=True)
            for forbidden in ('_thread_suspend','_thread_resume','_task_threads','_dlopen','_dispatch_after','_pthread_create','_posix_spawn'):
                self.assertNotIn(forbidden,imports)
        # Source constructor contains only a store; full bundle's ObjC/dependency
        # initialization and explicit installer are NOT claimed to be inert.

    def test_standalone_build_exports_and_no_automatic_entry(self):
        result = subprocess.run(['python3','-B',str(PROBE/'build_query_route_probe.py')],capture_output=True,text=True,timeout=120)
        self.assertEqual(result.returncode,0,result.stderr)
        output = Path(next(line.split(': ',1)[1] for line in result.stdout.splitlines() if line.startswith('BUILT local unsigned')))
        manifest = json.loads((output/'build-local.json').read_text())
        for key in ('installsOnLoad','receiveEnabled','summariesModified','healthSamplesRead','signed','packaged','deviceInstalled','safeDeviceLoaderImplemented','freshCacheProvenByProbe'):
            self.assertIs(manifest[key],False)
        for artifact in manifest['artifacts']:
            binary=output/artifact['file'];data=binary.read_bytes();header=struct.unpack_from('<8I',data);pos=32
            for _ in range(header[4]):
                cmd,size=struct.unpack_from('<II',data,pos)
                self.assertNotEqual(cmd,0x1d) # unsigned, no adhoc blob
                if cmd==0x19:
                    for i in range(struct.unpack_from('<I',data,pos+64)[0]):
                        section=data[pos+72+80*i:pos+88+80*i].split(b'\0')[0]
                        self.assertNotIn(section,(b'__mod_init_func',b'__init_offsets'))
                pos+=size
            symbols=subprocess.check_output(['xcrun','nm','-gU',str(binary)],text=True)
            exports=set(re.findall(r'\S+$',symbols,re.M))
            self.assertEqual(exports,{'_WFHSInstallQueryRouteProbe','_WFHSStopQueryRouteProbe','_WFHSCopyQueryRouteProbeReportV3'})
            imports=subprocess.check_output(['xcrun','nm','-u',str(binary)],text=True)
            if artifact['architecture']=='arm64e':
                self.assertIn('_method_setImplementation',imports)
            for forbidden in ('_object_getIvar','_HKHealthStore','_dlopen','_task_for_pid','_vm_read','_sqlite3','_posix_spawn','_sandbox_extension','_open','_write'):
                self.assertNotIn(forbidden,imports)
        for file in ('Makefile','App/Makefile','Modules/SleepSync/Makefile','Modules/SleepSync/stage_runtime.py'):
            self.assertNotIn('QueryRouteProbe',(PROJECT/file).read_text())
        self.assertFalse((PROBE/'Makefile').exists())
        self.assertFalse(list(PROBE.glob('*.plist')))

    def test_actual_method_boundaries_on_owned_classes(self):
        text = (PROBE / 'QueryRouteProbe.m').read_text()
        begin = text.index('static BOOL WFHSProbeCaller(')
        end = text.index('static void WFHSProbeFail(', begin)
        text = text[:begin] + 'static BOOL WFHSProbeCaller(const void *address,uintptr_t offset){(void)address;(void)offset;return fixtureCaller;}\n' + text[end:]
        text = text.replace('method_setImplementation(', 'FixtureSetImplementation(')
        # Insert after imports, before implementation needs the fixture value.
        text = text.replace('typedef struct {int64_t start,duration;} WFHSProbeRange;', MAIN + '\ntypedef struct {int64_t start,duration;} WFHSProbeRange;')
        with tempfile.TemporaryDirectory(prefix='query-route-probe-', dir=HERE) as temp:
            work = Path(temp)
            (work / 'main.m').write_text(text + INSTALL_FIXTURES + TEST)
            for optimization in ('-O0', '-O2'):
                command = ['xcrun','clang','-fobjc-arc','-fobjc-arc-exceptions',optimization,'-Wall','-Wextra','-Werror','-Wno-unused-function',
                           '-DWFHS_QUERY_ROUTE_PROBE=1','-fsanitize=address,undefined','-framework','Foundation',
                           '-I',str(PROBE),'-I',str(ADAPTER),str(work/'main.m'),str(ADAPTER/'LoadedMethodIdentity.m'),str(ADAPTER/'IOS154BoundaryIdentity.m'),'-o',str(work/'test')]
                result = subprocess.run(command,capture_output=True,text=True,timeout=60)
                self.assertEqual(result.returncode,0,result.stderr)
                run = subprocess.run([str(work/'test')],capture_output=True,text=True,timeout=10)
                self.assertEqual(run.returncode,0,run.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
