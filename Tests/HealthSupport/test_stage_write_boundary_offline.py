"""Exact existing insert ABI, fake manager/original only. No disk/HealthKit writes."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ADAPTER = PROJECT / 'Modules/HealthSupport/Adapters'
MAIN = r'''
#import "StageWriteBoundary.h"
#include <assert.h>
@interface GateType : NSObject
@property(nonatomic) NSInteger code;
@end
@implementation GateType @end
@interface GateCategory : NSObject
@property(nonatomic,strong) id sampleType;
@property(nonatomic) NSInteger value;
@end
@implementation GateCategory @end
@interface GateManager : NSObject
- (BOOL)insertDataObjects:(NSArray *)objects withProvenance:(id)p creationDate:(double)d
 skipInsertionFilter:(BOOL)s updateSourceOrder:(BOOL)u resolveAssociations:(BOOL)r error:(NSError **)e;
@end
@implementation GateManager
- (BOOL)insertDataObjects:(NSArray *)objects withProvenance:(id)p creationDate:(double)d
 skipInsertionFilter:(BOOL)s updateSourceOrder:(BOOL)u resolveAssociations:(BOOL)r error:(NSError **)e {
 (void)objects;(void)p;(void)d;(void)s;(void)u;(void)r;(void)e;abort(); // not called, no hook
}
@end
int main(void) {
 @autoreleasepool {
  GateManager *manager=[GateManager new];GateType *type=[GateType new];type.code=63;
  GateCategory *stage=[GateCategory new];stage.sampleType=type;stage.value=4;
  NSArray *objects=@[[NSObject new],stage];id provenance=[NSObject new];__block NSUInteger calls=0;
  WFHSOriginalStageInsert original=^BOOL(id m,NSArray *batch,id p,double d,BOOL s,BOOL u,BOOL r,NSError **e) {
   ++calls;assert(m==manager&&batch==objects&&p==provenance&&d==123.5&&s&&!u&&r);
   if(e)*e=nil;return YES;
  };
  NSError *error=nil;
  BOOL accepted=WFHSInsertWithStageWriteBoundary(manager,GateManager.class,objects,provenance,123.5,YES,NO,YES,
    &error,GateCategory.class,GateType.class,NO,10,original);
  assert(!accepted&&calls==0&&error.code==3&&[error.domain isEqual:@"WatchFix.HealthSupport.StageWriteBoundary"]);
  assert(stage.value==4&&objects.count==2);
  accepted=WFHSInsertWithStageWriteBoundary(manager,GateManager.class,objects,provenance,123.5,YES,NO,YES,
    &error,GateCategory.class,GateType.class,YES,10,original);
  assert(accepted&&calls==1&&!error);
  for(NSInteger value=0;value<3;++value) {
   stage.value=value;
   assert(WFHSInsertWithStageWriteBoundary(manager,GateManager.class,objects,provenance,123.5,YES,NO,YES,
    &error,GateCategory.class,GateType.class,NO,10,original));
  }
  stage.value=4;type.code=64;
  assert(WFHSInsertWithStageWriteBoundary(manager,GateManager.class,objects,provenance,123.5,YES,NO,YES,
    &error,GateCategory.class,GateType.class,NO,10,original));type.code=63;
  assert(!WFHSInsertWithStageWriteBoundary(manager,GateManager.class,objects,provenance,123.5,YES,NO,YES,
    NULL,GateCategory.class,GateType.class,NO,10,original));
  NSError *sentinel=[NSError errorWithDomain:@"OriginalFixture" code:7 userInfo:nil];
  WFHSOriginalStageInsert fails=^BOOL(id m,NSArray *b,id p,double d,BOOL s,BOOL u,BOOL r,NSError **e) {
   (void)m;(void)b;(void)p;(void)d;(void)s;(void)u;(void)r;if(e)*e=sentinel;return NO;
  };
  assert(!WFHSInsertWithStageWriteBoundary(manager,GateManager.class,objects,provenance,123.5,YES,NO,YES,
    &error,GateCategory.class,GateType.class,YES,10,fails)&&error==sentinel);
  __block BOOL caught=NO;
  WFHSOriginalStageInsert throws=^BOOL(id m,NSArray *b,id p,double d,BOOL s,BOOL u,BOOL r,NSError **e) {
   (void)m;(void)b;(void)p;(void)d;(void)s;(void)u;(void)r;(void)e;
   @throw[NSException exceptionWithName:@"OriginalThrows" reason:nil userInfo:nil];
  };
  @try {WFHSInsertWithStageWriteBoundary(manager,GateManager.class,objects,provenance,123.5,YES,NO,YES,
    &error,GateCategory.class,GateType.class,YES,10,throws);}
  @catch(NSException *exception){caught=[exception.name isEqual:@"OriginalThrows"];}
  assert(caught);
  puts("PASS actual insert ABI/stage batch refusal/read path separate/original arguments-error-exception preserved");
 }
}
'''


class StageWriteBoundaryTests(unittest.TestCase):
    def test_original_insert_boundary(self):
        with tempfile.TemporaryDirectory(prefix='write-boundary-host-', dir=HERE) as temporary:
            work = Path(temporary)
            source, binary = work / 'main.m', work / 'boundary'
            source.write_text(MAIN)
            for optimization in ('-O0', '-O2'):
                with self.subTest(optimization=optimization):
                    built = subprocess.run([
                        'xcrun', 'clang', '-fobjc-arc', optimization, '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-framework', 'Foundation', '-I', str(ADAPTER),
                        str(ADAPTER / 'StageWriteBoundary.m'), str(source), '-o', str(binary),
                    ], capture_output=True, text=True, timeout=60)
                    self.assertEqual(built.returncode, 0, built.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('original arguments-error-exception preserved', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
