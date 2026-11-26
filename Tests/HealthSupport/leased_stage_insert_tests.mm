#include "LeasedStageInsert.hpp"
#include "ModuleReadiness.hpp"
#include <fcntl.h>
#include <unistd.h>
#include <cassert>
#include <cstdio>
using namespace watchfix::healthsupport;
@interface LeaseType : NSObject
@property(nonatomic) NSInteger code;
@end
@implementation LeaseType @end
@interface LeaseCategory : NSObject
@property(nonatomic,strong) id sampleType;
@property(nonatomic) NSInteger value;
@end
@implementation LeaseCategory @end
@interface LeaseManager : NSObject
- (BOOL)insertDataObjects:(NSArray *)objects withProvenance:(id)p creationDate:(double)d
 skipInsertionFilter:(BOOL)s updateSourceOrder:(BOOL)u resolveAssociations:(BOOL)r error:(NSError **)e;
@end
@implementation LeaseManager
- (BOOL)insertDataObjects:(NSArray *)objects withProvenance:(id)p creationDate:(double)d
 skipInsertionFilter:(BOOL)s updateSourceOrder:(BOOL)u resolveAssociations:(BOOL)r error:(NSError **)e {
 (void)objects;(void)p;(void)d;(void)s;(void)u;(void)r;(void)e;abort();
}
@end
int main(int argc,char **argv) {
 @autoreleasepool {
  assert(argc==2);int fd=open(argv[1],O_RDONLY|O_DIRECTORY|O_CLOEXEC);assert(fd>=0);
  ReceiveGateStatus status;auto gate=ReceiveGate::initializeFresh(fd,status);assert(gate);close(fd);
  LeaseManager *manager=[LeaseManager new];LeaseType *type=[LeaseType new];type.code=63;
  LeaseCategory *sample=[LeaseCategory new];sample.sampleType=type;sample.value=4;NSArray *objects=@[sample];
  __block NSUInteger calls=0;NSError *error=nil;
  WFHSOriginalStageInsert original=^BOOL(id m,NSArray *o,id p,double d,BOOL s,BOOL u,BOOL r,NSError **out) {
   (void)p;assert(m==manager&&o==objects&&d==1.5&&s&&!u&&!r);++calls;
   assert(gate->inFlight()==1&&!gate->ownHistoryHasNoReadDependency());
   assert(gate->stop(std::chrono::milliseconds(0))==ReceiveGateStatus::draining);
   assert(!gate->enabled()&&!gate->acquire().allowed());if(out)*out=nil;return YES;
  };
  auto insert=[&](WFHSOriginalStageInsert callback) {
   return insertWithReceiveLease(gate,manager,LeaseManager.class,objects,nil,1.5,YES,NO,NO,&error,
     LeaseCategory.class,LeaseType.class,10,callback);
  };
  assert(!insert(original)&&calls==0&&gate->inFlight()==0);
  assert(gate->enable()==ReceiveGateStatus::complete);
  assert(insert(original)&&calls==1&&gate->inFlight()==0&&!gate->enabled());
  assert(gate->stop(std::chrono::milliseconds(0))==ReceiveGateStatus::complete);
  assert(!insert(original)&&calls==1); // subsequent stage refused after durable stop
  assert(gate->enable()==ReceiveGateStatus::complete);
  NSException *sentinel=[NSException exceptionWithName:@"Original" reason:nil userInfo:nil];BOOL caught=NO;
  WFHSOriginalStageInsert throws=^BOOL(id m,NSArray *o,id p,double d,BOOL s,BOOL u,BOOL r,NSError **out) {
   (void)m;(void)o;(void)p;(void)d;(void)s;(void)u;(void)r;(void)out;
   assert(gate->inFlight()==1);@throw sentinel;
  };
  @try {insert(throws);}@catch(NSException *exception){caught=exception==sentinel;}
  assert(caught&&gate->inFlight()==0);
  assert(gate->stop(std::chrono::milliseconds(0))==ReceiveGateStatus::complete);
  assert(!gate->ownHistoryHasNoReadDependency());
  assert(!ModuleReadiness::may_expand_sleep_acceptance());
  puts("PASS real receive lease through original insert/durable stop/inflight exception unwind/raw unchanged/no runtime enable");
 }
}
