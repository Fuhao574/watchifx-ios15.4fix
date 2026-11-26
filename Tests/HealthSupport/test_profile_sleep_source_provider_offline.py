"""Own profile/managers exercise actual15.4 selectors, no HealthKit/SQL queries."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'
MAIN = r'''
#import "ProfileSleepSourceProvider.h"
#import "SourceProviderAdapter.h"
#include <assert.h>
@interface SleepType : NSObject
@property(nonatomic) NSInteger code;
@end
@implementation SleepType @end
@interface OrderManager : NSObject
@property(nonatomic,strong) NSArray *answer;
@property(nonatomic,strong) id expectedType;
- (NSArray *)orderedSourceIDsForObjectType:(id)type bundleIdentifierMapping:(id)mapping userOrdered:(BOOL *)ordered error:(NSError **)error;
@end
@implementation OrderManager
- (NSArray *)orderedSourceIDsForObjectType:(id)type bundleIdentifierMapping:(id)mapping userOrdered:(BOOL *)ordered error:(NSError **)error {
 assert(type==self.expectedType&&!mapping&&!ordered);if(error)*error=[NSError errorWithDomain:@"native fixture" code:1 userInfo:nil];return self.answer;
}
@end
@interface SourceObject : NSObject
- (NSString *)bundleIdentifier;
@end
@implementation SourceObject
- (NSString *)bundleIdentifier{return @"fixture.bundle";}
@end
@interface SourceManager : NSObject
@property(nonatomic,strong) id answer;
@property(nonatomic,strong) NSNumber *seen;
- (id)clientSourceForPersistentID:(NSNumber *)identifier error:(NSError **)error;
@end
@implementation SourceManager
- (id)clientSourceForPersistentID:(NSNumber *)identifier error:(NSError **)error {
 self.seen=identifier;if(error)*error=nil;return self.answer;
}
@end
@interface Profile : NSObject
@property(nonatomic,strong) id sourceOrderManager,sourceManager;
@end
@implementation Profile @end
int main(void) {
 @autoreleasepool {
  WFHSProfileSleepSourceProvider *provider;__weak id weakProfile;
  @autoreleasepool {
   Profile *profile=[Profile new];OrderManager *order=[OrderManager new];SourceManager *sources=[SourceManager new];
   SleepType *type=[SleepType new];type.code=63;order.expectedType=type;
   profile.sourceOrderManager=order;profile.sourceManager=sources;
   provider=[[WFHSProfileSleepSourceProvider alloc]initWithProfile:profile profileClass:Profile.class
    sleepCategory:type categoryClass:SleepType.class sourceOrderManagerClass:OrderManager.class
    sourceManagerClass:SourceManager.class maximumSources:10];assert(provider);
   order.answer=@[@9,@100];
   WFHSSourceOrderAttempt *attempt=WFHSOrderRegisteredSourceIDs(provider,WFHSProfileSleepSourceProvider.class,@[@8,@9],10);
   assert(attempt.status==WFHSSourceProviderComplete&&attempt.orderedSourceIDs.count==1&&[attempt.orderedSourceIDs[0] isEqual:@9]);
   order.answer=@[];
   attempt=WFHSOrderRegisteredSourceIDs(provider,WFHSProfileSleepSourceProvider.class,@[@8,@9],10);
   assert(attempt.status==WFHSSourceProviderComplete&&attempt.orderedSourceIDs.count==0);
   order.answer=nil;
   attempt=WFHSOrderRegisteredSourceIDs(provider,WFHSProfileSleepSourceProvider.class,@[@8,@9],10);
   assert(attempt.status==WFHSSourceProviderComplete&&([attempt.orderedSourceIDs isEqual:@[@8,@9]]));
   SourceObject *source=[SourceObject new];sources.answer=source;
   WFHSBundleLookupAttempt *bundle=WFHSLookupSourceBundle(provider,WFHSProfileSleepSourceProvider.class,INT64_MIN,100);
   assert(bundle.status==WFHSSourceProviderComplete&&[bundle.bundleIdentifier isEqual:@"fixture.bundle"]&&sources.seen.longLongValue==INT64_MIN);
   sources.answer=nil;
   bundle=WFHSLookupSourceBundle(provider,WFHSProfileSleepSourceProvider.class,8,100);
   assert(bundle.status==WFHSSourceProviderComplete&&!bundle.bundleIdentifier);
   profile.sourceManager=[NSObject new];
   assert(WFHSLookupSourceBundle(provider,WFHSProfileSleepSourceProvider.class,8,100).status==WFHSSourceProviderCandidateException);
   profile.sourceManager=sources;order.answer=@[@9,@9];
   assert(WFHSOrderRegisteredSourceIDs(provider,WFHSProfileSleepSourceProvider.class,@[@8,@9],10).status==WFHSSourceProviderCandidateException);
   weakProfile=profile;profile=nil;
  }
  assert(!weakProfile);
  WFHSSourceOrderAttempt *attempt=WFHSOrderRegisteredSourceIDs(provider,WFHSProfileSleepSourceProvider.class,@[@8,@9],10);
  assert(attempt.status==WFHSSourceProviderComplete&&attempt.orderedSourceIDs.count==2);
  assert(WFHSLookupSourceBundle(provider,WFHSProfileSleepSourceProvider.class,8,100).status==WFHSSourceProviderComplete);
  puts("PASS actual profile/source managers/category63/subset-empty-vs-nil preference/weak profile/no quantity factory");
 }
}
'''


class ProfileSleepSourceProviderTests(unittest.TestCase):
    def test_native_manager_chain(self):
        with tempfile.TemporaryDirectory(prefix='profile-provider-host-', dir=HERE) as temporary:
            work = Path(temporary)
            source, binary = work / 'main.m', work / 'provider'
            source.write_text(MAIN)
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang', '-fobjc-arc', '-fobjc-arc-exceptions', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-framework', 'Foundation', '-I', str(ADAPTER),
                        str(ADAPTER / 'ProfileSleepSourceProvider.m'), str(ADAPTER / 'SourceProviderAdapter.m'),
                        str(source), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('no quantity factory', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
