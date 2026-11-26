#include "SleepSampleAdapter.hpp"
#include <cassert>
#include <cstdio>
using namespace watchfix::healthsupport;
@interface InputType : NSObject
@property(nonatomic) NSInteger code;
@end
@implementation InputType @end
@interface InputSource : NSObject
@property(nonatomic,strong) NSNumber *number;
- (NSNumber *)_sourceID;
@end
@implementation InputSource
- (NSNumber *)_sourceID{return self.number;}
@end
@interface InputRevision : NSObject
@property(nonatomic,strong) id source;
@end
@implementation InputRevision @end
@interface InputSample : NSObject
@property(nonatomic) NSInteger value;
@property(nonatomic,strong) id sampleType,sourceRevision;
@property(nonatomic,strong) NSDate *startDate,*endDate;
@property(nonatomic) BOOL shouldThrow;
@end
@implementation InputSample
@synthesize value=_value;
- (NSInteger)value {
    if(self.shouldThrow)@throw[NSException exceptionWithName:@"Fixture" reason:nil userInfo:nil];return _value;
}
@end
static InputSample *sample(NSInteger value,double start,double end,NSNumber *number) {
    InputSample *s=[InputSample new];InputType *t=[InputType new];t.code=63;
    InputSource *source=[InputSource new];source.number=number;
    InputRevision *r=[InputRevision new];r.source=source;
    s.sampleType=t;s.sourceRevision=r;s.value=value;
    s.startDate=[NSDate dateWithTimeIntervalSinceReferenceDate:start];s.endDate=[NSDate dateWithTimeIntervalSinceReferenceDate:end];return s;
}
static SleepSampleAttempt read(NSArray *samples) {
    return readSleepSampleSnapshot(samples,InputSample.class,InputType.class,InputRevision.class,InputSource.class);
}
int main() {
    @autoreleasepool {
        InputSample *bed=sample(0,-10,180,@8),*core=sample(3,0,120,@8),*awake=sample(2,60,90,@9),*rem=sample(5,120,180,@9);
        auto result=read(@[bed,core,awake,rem]);
        assert(result.complete()&&result.original_in_bed.count==1&&result.original_in_bed[0]==bed);
        assert(result.non_in_bed.size()==3&&result.non_in_bed[0].category==3&&result.non_in_bed[1].category==2&&result.non_in_bed[2].category==5);
        assert(result.non_in_bed[0].source_id==8&&result.non_in_bed[2].source_id==9);
        assert(core.value==3&&rem.value==5);
        result=read(@[]);assert(result.complete()&&result.non_in_bed.empty());
        result=read(@[rem,core]);assert(result.status==SleepSampleStatus::unordered_samples&&result.non_in_bed.empty()&&!result.original_in_bed);
        for(NSNumber *number in @[@8.5,@(UINT64_MAX)]){
            result=read(@[sample(3,0,60,number)]);assert(!result.complete()&&result.non_in_bed.empty());
        }
        result=read(@[sample(6,0,60,@8)]);assert(!result.complete());
        for(NSNumber *number in @[@(INT64_MIN),@(INT64_MAX)]) {
            result=read(@[sample(3,0,60,number)]);
            assert(result.complete()&&result.non_in_bed[0].source_id==number.longLongValue);
        }
        for(NSNumber *value in @[@0,@3])assert(!read(@[sample(value.integerValue,0,0,@8)]).complete());
        InputSample *bad=sample(5,140,180,@8.5);
        result=read(@[bed,core,bad]);assert(!result.complete()&&result.non_in_bed.empty()&&!result.original_in_bed);
        bad=sample(5,140,180,@8);bad.shouldThrow=YES;
        result=read(@[bed,core,bad]);assert(result.status==SleepSampleStatus::candidate_exception&&result.non_in_bed.empty()&&!result.original_in_bed);
        ((InputType *)core.sampleType).code=64;assert(!read(@[core]).complete());((InputType *)core.sampleType).code=63;
        core.shouldThrow=YES;result=read(@[core]);assert(result.status==SleepSampleStatus::candidate_exception&&result.non_in_bed.empty());core.shouldThrow=NO;
        result=readSleepSampleSnapshot(@[core,rem],InputSample.class,InputType.class,InputRevision.class,InputSource.class,1);
        assert(result.status==SleepSampleStatus::resource_limit);
        puts("PASS actual sample getter signatures/raw stages/Awake retained/original InBed/no sample creation");
    }
}
