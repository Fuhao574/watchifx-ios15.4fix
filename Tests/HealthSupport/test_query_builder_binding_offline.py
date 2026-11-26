"""Actual object identity association logic on own objects, no native hooks."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'
MAIN = r'''
#import "QueryBuilderBinding.h"
#include <assert.h>
@interface IdentityOnly : NSObject @end
@implementation IdentityOnly
- (NSUInteger)hash{abort();}
- (BOOL)isEqual:(id)object{(void)object;abort();}
@end
@interface ThrowingTable : NSObject
- (id)objectForKey:(id)key;
@end
@implementation ThrowingTable
- (id)objectForKey:(id)key {
 (void)key;@throw[NSException exceptionWithName:@"CandidateTable" reason:nil userInfo:nil];
}
@end
int main(void) {
 @autoreleasepool {
  __weak id weakProfile;
  WFHSBoundDayContext *retainedContext;
  WFHSQueryBinding *retainedBinding;
  @autoreleasepool {
  id enumerator=[IdentityOnly new],profile=[IdentityOnly new],cache=[IdentityOnly new],builder=[IdentityOnly new];
  WFHSQueryBinding *binding=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:10];
   assert(binding&&[binding beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]);
   assert([binding activeEnumerationGeneration]==1);
  assert([binding bindActualReturnedBuilder:builder initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
  WFHSBoundDayContext *context=[binding contextForBuilder:builder actualCache:cache];
  assert(context.profile==profile&&context.calendarCache==cache&&context.generation==1);
  assert(![binding contextForBuilder:[IdentityOnly new] actualCache:cache]);
  assert(![binding contextForBuilder:builder actualCache:[IdentityOnly new]]);
   [binding endEnumeration];assert(![binding contextForBuilder:builder actualCache:cache]);
   assert([binding activeEnumerationGeneration]==0);
  assert(context.profile==profile&&context.generation==1); // snapshot isn't automatically revoked
   assert([binding beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]);
   assert([binding activeEnumerationGeneration]==2);
  assert(![binding contextForBuilder:builder actualCache:cache]); // old generation not current
  id next=[IdentityOnly new];
  assert([binding bindActualReturnedBuilder:next initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
   assert([binding contextForBuilder:next actualCache:cache].generation==2);
   assert(![binding endEnumerationForGeneration:0]);
   assert(![binding endEnumerationForGeneration:1]);
   assert([binding activeEnumerationGeneration]==2&&[binding contextForBuilder:next actualCache:cache]);
  assert(![binding bindActualReturnedBuilder:next initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
   assert(![binding contextForBuilder:next actualCache:cache]); // repeated init poisons context
   assert(![binding endEnumerationForGeneration:2]);
   WFHSQueryBinding *scoped=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:10];
   assert([scoped beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]);
   assert([scoped endEnumerationForGeneration:1]);
   assert(![scoped endEnumerationForGeneration:1]&&[scoped activeEnumerationGeneration]==0);
  binding=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:10];
  assert([binding beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]);
  assert(![binding beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]); // reentry
  assert(![binding bindActualReturnedBuilder:builder initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
  binding=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:10];
  assert([binding beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]);
  assert(![binding bindActualReturnedBuilder:builder initializationCache:cache verifiedFactoryForThisEnumeration:NO]);
  binding=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:10];
  assert([binding beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]);
  assert([binding bindActualReturnedBuilder:builder initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
  assert(![binding bindActualReturnedBuilder:builder initializationCache:nil verifiedFactoryForThisEnumeration:YES]);
  assert(![binding contextForBuilder:builder actualCache:cache]);
  binding=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:1];
  assert([binding beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]);
  assert([binding bindActualReturnedBuilder:builder initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
  assert(![binding bindActualReturnedBuilder:[IdentityOnly new] initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
  assert(![binding contextForBuilder:builder actualCache:cache]);
  binding=[[WFHSQueryBinding alloc]initWithActualEnumerator:enumerator profile:profile freshCalendarCache:cache maximumBuilders:10];
  assert([binding beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]);
  [binding setValue:[ThrowingTable new] forKey:@"builders"]; // self-owned fixture injection, no native ivar writes
  assert(![binding bindActualReturnedBuilder:builder initializationCache:cache verifiedFactoryForThisEnumeration:YES]);
  assert(![binding beginEnumerationFor:enumerator actualProfile:profile actualCache:cache]);
  weakProfile=profile;retainedContext=context;retainedBinding=binding;profile=nil;
  }
  // Weak-load temporaries are permitted to survive until inner pool drain.
  assert(!weakProfile&&!retainedContext.profile);
  assert(retainedBinding); // still alive, but didn't keep profile alive
  puts("PASS explicit enumerator-cache-builder identity/no TLS/weak profile/generation/reentry rejection");
 }
}
'''


class QueryBuilderBindingTests(unittest.TestCase):
    def test_explicit_object_identity_and_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix='query-binding-host-', dir=HERE) as temporary:
            work = Path(temporary)
            source, binary = work / 'main.m', work / 'binding'
            source.write_text(MAIN)
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang', '-fobjc-arc', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-framework', 'Foundation', '-I', str(ADAPTER),
                        str(ADAPTER / 'QueryBuilderBinding.m'), str(source), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('reentry rejection', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
