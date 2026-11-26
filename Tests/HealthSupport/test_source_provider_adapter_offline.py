"""Own Foundation provider/source fixtures, never native HealthKit queries."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'
MAIN = r'''
#import "SourceProviderAdapter.h"
#include <assert.h>
static NSUInteger orders,lookups;
@interface Source : NSObject
@property(nonatomic,strong) id bundle;
- (NSString *)bundleIdentifier;
@end
@implementation Source
- (NSString *)bundleIdentifier {return self.bundle;}
@end
@interface Provider : NSObject
@property(nonatomic,strong) NSArray *result;
@property(nonatomic,strong) id source;
@property(nonatomic) BOOL throws;
- (NSArray *)orderedSourceIDsWithUnorderedIDs:(NSArray *)ids;
- (id)sourceForSourceID:(int64_t)source;
@end
@implementation Provider
- (NSArray *)orderedSourceIDsWithUnorderedIDs:(NSArray *)ids {
 ++orders;if(self.throws)@throw [NSException exceptionWithName:@"Fixture" reason:nil userInfo:nil];
 return self.result?:ids;
}
- (id)sourceForSourceID:(int64_t)source {
 (void)source;++lookups;if(self.throws)@throw [NSException exceptionWithName:@"Fixture" reason:nil userInfo:nil];
 return self.source;
}
@end
@interface DerivedProvider : Provider @end
@implementation DerivedProvider @end
@interface Pretender : NSObject @end
@implementation Pretender
- (BOOL)isKindOfClass:(Class)cls { (void)cls; return YES; }
@end
static NSUInteger stringCopies,stringEncodes;
@interface OversizedString : NSString @end
@implementation OversizedString
- (NSUInteger)length { return 1000000; }
- (unichar)characterAtIndex:(NSUInteger)index { (void)index; return 'a'; }
- (id)copyWithZone:(NSZone *)zone { (void)zone; ++stringCopies; return self; }
- (NSData *)dataUsingEncoding:(NSStringEncoding)encoding allowLossyConversion:(BOOL)lossy {
 (void)encoding;(void)lossy;++stringEncodes;return [NSData data];
}
@end
int main(void) {
 @autoreleasepool {
  Provider *provider=[Provider new];provider.result=@[@9,@8,@0,@(-1)];
  WFHSSourceOrderAttempt *attempt=WFHSOrderRegisteredSourceIDs(provider,Provider.class,@[@8,@9,@0,@(-1)],10);
  assert(attempt.status==WFHSSourceProviderComplete&&attempt.orderedSourceIDs.count==4);
  assert([attempt.orderedSourceIDs isEqual:provider.result]&&orders==1);
  provider.result=@[@8,@8];
  assert(WFHSOrderRegisteredSourceIDs(provider,Provider.class,@[@8,@9],10).status==WFHSSourceProviderInvalidNativeResult);
  provider.result=@[@8,@10];
  assert(WFHSOrderRegisteredSourceIDs(provider,Provider.class,@[@8,@9],10).status==WFHSSourceProviderInvalidNativeResult);
  provider.result=@[@8];
  attempt=WFHSOrderRegisteredSourceIDs(provider,Provider.class,@[@8,@9],10);
  assert(attempt.status==WFHSSourceProviderComplete&&attempt.orderedSourceIDs.count==1);
  provider.result=@[];
  attempt=WFHSOrderRegisteredSourceIDs(provider,Provider.class,@[@8,@9],10);
  assert(attempt.status==WFHSSourceProviderComplete&&attempt.orderedSourceIDs&&attempt.orderedSourceIDs.count==0);
  NSUInteger before=orders;
  assert(WFHSOrderRegisteredSourceIDs(provider,Provider.class,@[@8,@8],10).status==WFHSSourceProviderInvalidInput);
  assert(WFHSOrderRegisteredSourceIDs(provider,Provider.class,@[@8.5],10).status==WFHSSourceProviderInvalidInput);
  assert(WFHSOrderRegisteredSourceIDs(provider,Provider.class,@[@(UINT64_MAX)],10).status==WFHSSourceProviderInvalidInput);
  assert(WFHSOrderRegisteredSourceIDs(provider,Provider.class,@[@8,@9],1).status==WFHSSourceProviderInvalidInput);
  assert(WFHSOrderRegisteredSourceIDs([DerivedProvider new],Provider.class,@[@8],10).status==WFHSSourceProviderUnverified);
  assert(orders==before);
  provider.result=@[];
  assert(WFHSOrderRegisteredSourceIDs(provider,Provider.class,@[],10).status==WFHSSourceProviderComplete);
  WFHSBundleLookupAttempt *lookup=WFHSLookupSourceBundle(provider,Provider.class,8,100);
  assert(lookup.status==WFHSSourceProviderComplete&&!lookup.bundleIdentifier);
  Source *source=[Source new];provider.source=source;
  lookup=WFHSLookupSourceBundle(provider,Provider.class,8,100);
  assert(lookup.status==WFHSSourceProviderComplete&&!lookup.bundleIdentifier);
  source.bundle=@"";
  lookup=WFHSLookupSourceBundle(provider,Provider.class,8,100);
  assert(lookup.status==WFHSSourceProviderComplete&&lookup.bundleIdentifier&&lookup.bundleIdentifier.length==0);
  source.bundle=@"fixture.bundle";
  lookup=WFHSLookupSourceBundle(provider,Provider.class,8,100);
  assert(lookup.status==WFHSSourceProviderComplete&&[lookup.bundleIdentifier isEqual:@"fixture.bundle"]);
  assert(WFHSLookupSourceBundle(provider,Provider.class,8,1).status==WFHSSourceProviderInvalidNativeResult);
  source.bundle=@"中文";
  assert(WFHSLookupSourceBundle(provider,Provider.class,8,4).status==WFHSSourceProviderInvalidNativeResult);
  assert(WFHSLookupSourceBundle(provider,Provider.class,8,6).status==WFHSSourceProviderComplete);
  source.bundle=[OversizedString new];
  assert(WFHSLookupSourceBundle(provider,Provider.class,8,4096).status==WFHSSourceProviderInvalidNativeResult);
  assert(stringCopies==0&&stringEncodes==0);
  unichar embedded[]={ 'a',0,'b' };
  source.bundle=[NSString stringWithCharacters:embedded length:3];
  lookup=WFHSLookupSourceBundle(provider,Provider.class,8,3);
  assert(lookup.status==WFHSSourceProviderComplete&&lookup.bundleIdentifier.length==3);
  source.bundle=@8;
  assert(WFHSLookupSourceBundle(provider,Provider.class,8,100).status==WFHSSourceProviderInvalidNativeResult);
  source.bundle=[Pretender new];
  assert(WFHSLookupSourceBundle(provider,Provider.class,8,100).status==WFHSSourceProviderInvalidNativeResult);
  provider.result=(id)[Pretender new];
  assert(WFHSOrderRegisteredSourceIDs(provider,Provider.class,@[@8],10).status==WFHSSourceProviderInvalidNativeResult);
  provider.throws=YES;
  assert(WFHSLookupSourceBundle(provider,Provider.class,8,100).status==WFHSSourceProviderCandidateException);
  assert(WFHSOrderRegisteredSourceIDs(provider,Provider.class,@[@8],10).status==WFHSSourceProviderCandidateException);
  assert(lookups>0);
  puts("PASS source provider adapter/membership/nil-vs-failure/bundle limits/no HealthKit");
 }
 return 0;
}
'''


class SourceProviderAdapterTests(unittest.TestCase):
    def test_own_provider_and_source(self):
        with tempfile.TemporaryDirectory(prefix='provider-host-', dir=HERE) as temporary:
            work = Path(temporary)
            source, binary = work / 'main.m', work / 'provider'
            source.write_text(MAIN)
            built = subprocess.run([
                'xcrun', 'clang', '-fobjc-arc', '-O2', '-Wall', '-Wextra', '-Werror',
                '-fsanitize=address,undefined', '-framework', 'Foundation', '-I', str(ADAPTER),
                str(ADAPTER / 'SourceProviderAdapter.m'), str(source), '-o', str(binary),
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('no HealthKit', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
