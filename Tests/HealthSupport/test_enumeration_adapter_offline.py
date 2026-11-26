"""Explicit native-shaped enumeration boundary with own objects/original block."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'
MAIN = r'''
#import "EnumerationAdapter.h"
#include <assert.h>
static WFHSQueryBinding *binding(id e,id p,id c) {
 return [[WFHSQueryBinding alloc]initWithActualEnumerator:e profile:p freshCalendarCache:c maximumBuilders:10];
}
int main(void) {
 @autoreleasepool {
  id e=[NSObject new],p=[NSObject new],c=[NSObject new],b=[NSObject new],first=[NSObject new],second=[NSObject new];
  WFHSQueryBinding *bound=binding(e,p,c);__block NSUInteger deliveries=0,calls=0;NSError *error=nil;
  WFHSSleepSummaryHandler handler=^(id summary,BOOL *stop){assert(summary==first&&stop);++deliveries;};
  WFHSOriginalSleepEnumeration original=^BOOL(NSError **out,WFHSSleepSummaryHandler deliver,WFHSEnumerationFailure *failure) {
   ++calls;assert([bound bindActualReturnedBuilder:b initializationCache:c verifiedFactoryForThisEnumeration:YES]);
   assert([failure allowsCandidateForBinding:bound builder:b actualCache:c]);
   BOOL stop=NO;deliver(first,&stop);assert(!stop);
   assert([failure recordCandidateFailureForBuilder:b actualCache:c code:7]);
   assert(![failure allowsCandidateForBinding:bound builder:b actualCache:c]);
   deliver(second,&stop);assert(stop);if(out)*out=nil;return YES;
  };
  BOOL success=WFHSEnumerateBoundSleepSummaries(bound,e,p,c,10,2,10,&error,handler,original);
  assert(!success&&deliveries==1&&calls==1&&error.code==7&&[error.domain isEqual:@"WatchFix.HealthSupport.SleepEnumeration"]);
   assert(![bound contextForBuilder:b actualCache:c]);
   assert([bound activeEnumerationGeneration]==0);
  // NULL NSError still returns NO; never partial success simply because caller discarded error.
  bound=binding(e,p,c);
  WFHSEnumerationFailure *__block retainedFailure=nil;
  original=^BOOL(NSError **out,WFHSSleepSummaryHandler deliver,WFHSEnumerationFailure *failure) {
   (void)deliver;(void)out;retainedFailure=failure;
   assert([bound bindActualReturnedBuilder:b initializationCache:c verifiedFactoryForThisEnumeration:YES]);
   [failure recordCandidateFailureForBuilder:b actualCache:c code:8];return YES;
  };
  assert(!WFHSEnumerateBoundSleepSummaries(bound,e,p,c,10,2,10,NULL,handler,original));
   [retainedFailure recordCandidateFailureForBuilder:b actualCache:c code:9]; // closed operation ignored
   assert(![retainedFailure allowsCandidateForBinding:bound builder:b actualCache:c]);
  bound=binding(e,p,c);
  original=^BOOL(NSError **out,WFHSSleepSummaryHandler deliver,WFHSEnumerationFailure *failure) {
   (void)out;(void)deliver;
   assert([bound bindActualReturnedBuilder:b initializationCache:c verifiedFactoryForThisEnumeration:YES]);
   assert([failure recordCandidateFailureForBuilder:b actualCache:c code:10]);return NO;
  };
  assert(!WFHSEnumerateBoundSleepSummaries(bound,e,p,c,10,2,10,&error,handler,original)&&error.code==10);
  bound=binding(e,p,c);
  original=^BOOL(NSError **out,WFHSSleepSummaryHandler deliver,WFHSEnumerationFailure *failure) {
   assert(![failure recordCandidateFailureForBuilder:[NSObject new] actualCache:c code:11]);
   assert(![failure recordCandidateFailureForBuilder:b actualCache:[NSObject new] code:11]);
   BOOL stop=NO;deliver(first,&stop);assert(!stop);if(out)*out=nil;return YES;
  };
  assert(WFHSEnumerateBoundSleepSummaries(bound,e,p,c,10,2,10,&error,handler,original)&&!error);
  NSError *native=[NSError errorWithDomain:@"NativeFixture" code:12 userInfo:nil];
  bound=binding(e,p,c);
  original=^BOOL(NSError **out,WFHSSleepSummaryHandler deliver,WFHSEnumerationFailure *failure) {
   (void)deliver;assert([bound bindActualReturnedBuilder:b initializationCache:c verifiedFactoryForThisEnumeration:YES]);
   assert([failure recordCandidateFailureForBuilder:b actualCache:c code:7]);if(out)*out=native;return NO;
  };
   assert(!WFHSEnumerateBoundSleepSummaries(bound,e,p,c,10,2,10,&error,handler,original)&&error==native);
   // Open operation mismatches latch a protocol failure, not an invented builder error.
   for(NSUInteger kind=0;kind<3;++kind) {
    bound=binding(e,p,c);WFHSQueryBinding *foreign=binding(e,p,c);
    original=^BOOL(NSError **out,WFHSSleepSummaryHandler deliver,WFHSEnumerationFailure *failure) {
     (void)out;(void)deliver;assert([bound bindActualReturnedBuilder:b initializationCache:c verifiedFactoryForThisEnumeration:YES]);
     assert(![failure allowsCandidateForBinding:kind==0?foreign:bound builder:kind==1?[NSObject new]:b actualCache:kind==2?[NSObject new]:c]);
     assert(![failure allowsCandidateForBinding:bound builder:b actualCache:c]);return YES;
    };
    assert(!WFHSEnumerateBoundSleepSummaries(bound,e,p,c,10,2,10,&error,handler,original)&&error.code==1);
   }
   // The old open channel must not attach itself to a later binding generation.
   bound=binding(e,p,c);
   original=^BOOL(NSError **out,WFHSSleepSummaryHandler deliver,WFHSEnumerationFailure *failure) {
    (void)out;(void)deliver;[bound endEnumeration];
    assert([bound beginEnumerationFor:e actualProfile:p actualCache:c]);
    assert([bound bindActualReturnedBuilder:b initializationCache:c verifiedFactoryForThisEnumeration:YES]);
    assert(![failure allowsCandidateForBinding:bound builder:b actualCache:c]);return YES;
   };
   assert(!WFHSEnumerateBoundSleepSummaries(bound,e,p,c,10,2,10,&error,handler,original)&&error.code==1);
   assert([bound activeEnumerationGeneration]==2); // old finally must not close the newer operation
   assert([bound contextForBuilder:b actualCache:c]);
   assert([bound endEnumerationForGeneration:2]);
   // No create/delivery is necessary to detect explicit end/rebegin protocol drift.
   bound=binding(e,p,c);
   original=^BOOL(NSError **out,WFHSSleepSummaryHandler deliver,WFHSEnumerationFailure *failure) {
    (void)out;(void)deliver;(void)failure;[bound invalidate];return YES;
   };
   assert(!WFHSEnumerateBoundSleepSummaries(bound,e,p,c,10,2,10,&error,handler,original)&&error.code==1);
  bound=binding(e,p,c);
  original=^BOOL(NSError **out,WFHSSleepSummaryHandler deliver,WFHSEnumerationFailure *failure) {
   (void)failure;BOOL stop=NO;deliver(first,&stop);assert(stop);if(out)*out=nil;return YES;
  };
  WFHSSleepSummaryHandler stopping=^(id summary,BOOL *stop){assert(summary==first);*stop=YES;};
  assert(WFHSEnumerateBoundSleepSummaries(bound,e,p,c,10,2,10,&error,stopping,original)&&!error);
  bound=binding(e,p,c);calls=0;
  original=^BOOL(NSError **out,WFHSSleepSummaryHandler deliver,WFHSEnumerationFailure *failure) {
   (void)out;(void)deliver;(void)failure;++calls;return YES;
  };
  assert(!WFHSEnumerateBoundSleepSummaries(bound,e,p,c,0,0,10,&error,handler,original));
  assert(!WFHSEnumerateBoundSleepSummaries(bound,e,p,c,INT64_MAX,1,10,&error,handler,original));
  assert(!WFHSEnumerateBoundSleepSummaries(bound,e,p,c,0,11,10,&error,handler,original)&&calls==0);
  bound=binding(e,p,c);NSException *sentinel=[NSException exceptionWithName:@"Original" reason:nil userInfo:nil];
  original=^BOOL(NSError **out,WFHSSleepSummaryHandler deliver,WFHSEnumerationFailure *failure) {
   (void)out;(void)deliver;(void)failure;@throw sentinel;
  };
  BOOL caught=NO;@try{WFHSEnumerateBoundSleepSummaries(bound,e,p,c,10,2,10,&error,handler,original);}
   @catch(NSException *exception){caught=exception==sentinel;}assert(caught);
   // Exception cleanup is generation-scoped as well; preserve the exact exception.
   bound=binding(e,p,c);
   original=^BOOL(NSError **out,WFHSSleepSummaryHandler deliver,WFHSEnumerationFailure *failure) {
    (void)out;(void)deliver;(void)failure;[bound endEnumeration];
    assert([bound beginEnumerationFor:e actualProfile:p actualCache:c]);
    assert([bound bindActualReturnedBuilder:b initializationCache:c verifiedFactoryForThisEnumeration:YES]);
    @throw sentinel;
   };
   caught=NO;@try{WFHSEnumerateBoundSleepSummaries(bound,e,p,c,10,2,10,&error,handler,original);}
   @catch(NSException *exception){caught=exception==sentinel;}
   assert(caught&&[bound activeEnumerationGeneration]==2&&[bound contextForBuilder:b actualCache:c]);
   assert([bound endEnumerationForGeneration:2]);
  puts("PASS explicit bound enumeration/terminal candidate error/prior deliveries not recalled/native error-stop-exception preserved");
 }
}
'''


class EnumerationAdapterTests(unittest.TestCase):
    def test_terminal_failure_and_original_semantics(self):
        with tempfile.TemporaryDirectory(prefix='enumeration-host-', dir=HERE) as temporary:
            work = Path(temporary)
            source, binary = work / 'main.m', work / 'enumeration'
            source.write_text(MAIN)
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang', '-fobjc-arc', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-framework', 'Foundation', '-I', str(ADAPTER),
                        str(ADAPTER / 'QueryBuilderBinding.m'), str(ADAPTER / 'EnumerationAdapter.m'),
                        str(source), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('native error-stop-exception preserved', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
