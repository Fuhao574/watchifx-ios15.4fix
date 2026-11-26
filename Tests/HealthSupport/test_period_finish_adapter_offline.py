"""Compile own guard and fake native builder. Never executes HealthDaemon."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'
MAIN = r'''
#import "PeriodFinishAdapter.h"
#include <assert.h>
@interface GuardBuilder : NSObject {
@public
 NSMutableArray *_periods,*_segments;
 NSDate *_minDate,*_maxDate;
}
@end
@implementation GuardBuilder @end
@interface DerivedGuardBuilder : GuardBuilder @end
@implementation DerivedGuardBuilder @end
@interface ExtraGuardBuilder : GuardBuilder {id _extra;} @end
@implementation ExtraGuardBuilder @end
@interface WrongFieldBuilder : NSObject {
 NSMutableArray *_periods,*_segments;NSDate *_minDate;NSString *_maxDate;
}
@end
@implementation WrongFieldBuilder @end
@interface ThrowCopyArray : NSMutableArray @end
@implementation ThrowCopyArray
- (NSUInteger)count{return 0;}
- (id)copyWithZone:(NSZone *)zone {
 (void)zone;@throw[NSException exceptionWithName:@"CandidateCopy" reason:nil userInfo:nil];
}
@end
int main(void) {
 @autoreleasepool {
  GuardBuilder *builder=[GuardBuilder new];builder->_periods=[NSMutableArray array];builder->_segments=[NSMutableArray array];
  Class mutableClass=object_getClass(builder->_periods),emptyClass=object_getClass([builder->_periods copy]);
  __block NSUInteger calls=0;
  WFHSOriginalPeriodFinish original=^NSArray *(id actual) {
   assert(actual==builder);++calls;return @[@"native period fixture"];
  };
  WFHSPeriodFinishAttempt *attempt=WFHSFinishPeriodWithEmptyGuard(builder,GuardBuilder.class,mutableClass,emptyClass,original);
  assert(attempt.status==WFHSPeriodFinishProtectedEmpty&&attempt.periods&&attempt.periods.count==0&&calls==0);
  assert(builder->_periods.count==0&&builder->_segments.count==0&&!builder->_minDate&&!builder->_maxDate);
  [builder->_segments addObject:[NSObject new]];
  attempt=WFHSFinishPeriodWithEmptyGuard(builder,GuardBuilder.class,mutableClass,emptyClass,original);
  assert(attempt.status==WFHSPeriodFinishOriginalComplete&&calls==1&&attempt.periods.count==1);
  [builder->_segments removeAllObjects];
  [builder->_periods addObject:[NSObject new]];
  attempt=WFHSFinishPeriodWithEmptyGuard(builder,GuardBuilder.class,mutableClass,emptyClass,original);
  assert(attempt.status==WFHSPeriodFinishOriginalComplete&&calls==2); // repeat finish not falsely protected
  [builder->_periods removeAllObjects];
  builder->_minDate=[NSDate date];
  attempt=WFHSFinishPeriodWithEmptyGuard(builder,GuardBuilder.class,mutableClass,emptyClass,original);
  assert(attempt.status==WFHSPeriodFinishOriginalComplete&&calls==3);builder->_minDate=nil;
  builder->_maxDate=[NSDate date];
  attempt=WFHSFinishPeriodWithEmptyGuard(builder,GuardBuilder.class,mutableClass,emptyClass,original);
  assert(attempt.status==WFHSPeriodFinishOriginalComplete&&calls==4);builder->_maxDate=nil;
  attempt=WFHSFinishPeriodWithEmptyGuard(builder,GuardBuilder.class,mutableClass,NSObject.class,original);
  assert(attempt.status==WFHSPeriodFinishCandidateFailed&&!attempt.periods&&calls==4);
  attempt=WFHSFinishPeriodWithEmptyGuard([DerivedGuardBuilder new],GuardBuilder.class,mutableClass,emptyClass,original);
  assert(attempt.status==WFHSPeriodFinishUnverified&&!attempt.periods&&calls==4);
  attempt=WFHSFinishPeriodWithEmptyGuard([ExtraGuardBuilder new],ExtraGuardBuilder.class,mutableClass,emptyClass,original);
  assert(attempt.status==WFHSPeriodFinishUnverified&&!attempt.periods&&calls==4);
  attempt=WFHSFinishPeriodWithEmptyGuard([WrongFieldBuilder new],WrongFieldBuilder.class,mutableClass,emptyClass,original);
  assert(attempt.status==WFHSPeriodFinishUnverified&&!attempt.periods&&calls==4);
  builder->_segments=nil;
  attempt=WFHSFinishPeriodWithEmptyGuard(builder,GuardBuilder.class,mutableClass,emptyClass,original);
  assert(attempt.status==WFHSPeriodFinishUnverified&&!attempt.periods&&calls==4);
  builder->_segments=[NSMutableArray array];builder->_periods=[ThrowCopyArray new];
  attempt=WFHSFinishPeriodWithEmptyGuard(builder,GuardBuilder.class,ThrowCopyArray.class,emptyClass,original);
  assert(attempt.status==WFHSPeriodFinishUnverified&&calls==4); // both concrete source classes must match
  builder->_segments=[ThrowCopyArray new];
  attempt=WFHSFinishPeriodWithEmptyGuard(builder,GuardBuilder.class,ThrowCopyArray.class,emptyClass,original);
  assert(attempt.status==WFHSPeriodFinishCandidateFailed&&!attempt.periods&&calls==4);
  builder->_periods=[NSMutableArray arrayWithObject:[NSObject new]];builder->_segments=[NSMutableArray array];
  NSException *sentinel=[NSException exceptionWithName:@"OriginalFailure" reason:nil userInfo:nil];
  WFHSOriginalPeriodFinish throws=^NSArray *(id actual){(void)actual;@throw sentinel;};
  BOOL caught=NO;
  @try {WFHSFinishPeriodWithEmptyGuard(builder,GuardBuilder.class,mutableClass,emptyClass,throws);}
  @catch(NSException *exception){caught=exception==sentinel;}
  assert(caught);
  puts("PASS module original-finish adapter/exact four-field empty guard/no original on copy failure/original exception preserved");
 }
}
'''


class PeriodFinishAdapterTests(unittest.TestCase):
    def test_original_finish_or_narrow_empty_guard(self):
        with tempfile.TemporaryDirectory(prefix='period-finish-host-', dir=HERE) as temporary:
            work = Path(temporary)
            source, binary = work / 'main.m', work / 'finish'
            source.write_text('#import <objc/runtime.h>\n' + MAIN)
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang', '-fobjc-arc', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-framework', 'Foundation', '-I', str(ADAPTER),
                        str(ADAPTER / 'PeriodFinishAdapter.m'), str(source), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('original exception preserved', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
