#include "LegacyPeriodAdapter.hpp"
#include "ModuleReadiness.hpp"
#include <cassert>
#include <cstdio>

using namespace watchfix::healthsupport;
static NSUInteger allocatedBuilders, finishes;
static BOOL factoryFails, builderThrows;
static NSInteger corruptPeriod;
static BOOL lyingEnvelope;
@interface EqualLyingInterval : NSDateInterval
@property(nonatomic,strong) NSDate *first,*last;
@end
@implementation EqualLyingInterval
- (NSDate *)startDate{return self.first;}
- (NSDate *)endDate{return self.last;}
- (BOOL)isEqual:(id)other{(void)other;return YES;}
@end
@interface OutputSegment : NSObject
@property(nonatomic,strong) NSDateInterval *dateInterval;
@property(nonatomic,strong) NSArray *sampleIntervals;
@property(nonatomic) NSInteger category;
@property(nonatomic) BOOL containsAppleSleepTrackingData;
+ (id)sleepPeriodSegmentWithDateInterval:(NSDateInterval *)interval sampleIntervals:(NSArray *)samples
    category:(NSInteger)category containsAppleSleepTrackingData:(BOOL)containsApple;
@end
@implementation OutputSegment
+ (id)sleepPeriodSegmentWithDateInterval:(NSDateInterval *)interval sampleIntervals:(NSArray *)samples
    category:(NSInteger)category containsAppleSleepTrackingData:(BOOL)containsApple {
    if (factoryFails) return nil;
    OutputSegment *value=[self new];value.dateInterval=interval;value.sampleIntervals=[samples copy];
    if(lyingEnvelope) {
        EqualLyingInterval *wrong=[EqualLyingInterval new];wrong.first=interval.startDate;
        wrong.last=[interval.endDate dateByAddingTimeInterval:1];value.dateInterval=wrong;
    }
    value.category=category;value.containsAppleSleepTrackingData=containsApple;return value;
}
@end
@interface OutputPeriod : NSObject
@property(nonatomic,strong) NSArray *segments;
@property(nonatomic,strong) NSDateInterval *dateInterval;
@end
@implementation OutputPeriod @end
@interface OutputSummary : NSObject
@property(nonatomic) NSInteger morningIndex;
@property(nonatomic,strong) NSDateInterval *dateInterval;
@property(nonatomic,strong) NSCalendar *calendar;
@property(nonatomic,strong) NSArray *periods,*schedules;
@property(nonatomic,strong) id sleepDurationGoal;
+ (id)daySummaryWithMorningIndex:(NSInteger)index dateInterval:(NSDateInterval *)interval
    calendar:(NSCalendar *)calendar periods:(NSArray *)periods schedules:(NSArray *)schedules sleepDurationGoal:(id)goal;
@end
@implementation OutputSummary
+ (id)daySummaryWithMorningIndex:(NSInteger)index dateInterval:(NSDateInterval *)interval
    calendar:(NSCalendar *)calendar periods:(NSArray *)periods schedules:(NSArray *)schedules sleepDurationGoal:(id)goal {
    OutputSummary *value=[self new];value.morningIndex=index;value.dateInterval=interval;value.calendar=[calendar copy];
    value.periods=[periods copy];value.schedules=[schedules copy];value.sleepDurationGoal=goal;return value;
}
@end
@interface OutputBuilder : NSObject
@property(nonatomic,strong) NSMutableArray *segments;
- (void)addOrderedSegment:(id)segment;
- (NSArray *)finish;
@end
@implementation OutputBuilder
- (instancetype)init {
    if ((self=[super init])) {++allocatedBuilders;self.segments=[NSMutableArray array];}return self;
}
- (void)addOrderedSegment:(id)segment {
    if (builderThrows) @throw [NSException exceptionWithName:@"Fixture" reason:nil userInfo:nil];
    [self.segments addObject:segment];
}
- (NSArray *)finish {
    ++finishes;assert(self.segments.count); // forbidden empty finish must not occur
    OutputPeriod *period=[OutputPeriod new];period.segments=[self.segments copy];
    NSDate *start=nil,*end=nil;
    for(OutputSegment *segment in self.segments) {
        start=start?[start earlierDate:segment.dateInterval.startDate]:segment.dateInterval.startDate;
        end=end?[end laterDate:segment.dateInterval.endDate]:segment.dateInterval.endDate;
    }
    period.dateInterval=[[NSDateInterval alloc]initWithStartDate:start endDate:end];
    if(corruptPeriod==1)period.segments=@[];
    if(corruptPeriod==2)period.segments=@[self.segments[0],self.segments[0]];
    if(corruptPeriod==3)period.dateInterval=[[NSDateInterval alloc]initWithStartDate:start duration:1];
    if(corruptPeriod==4)period.segments=@[self.segments[0]];
    return @[period];
}
@end
static NSDateInterval *interval(double start,double end) {
    return [[NSDateInterval alloc] initWithStartDate:[NSDate dateWithTimeIntervalSinceReferenceDate:start]
        endDate:[NSDate dateWithTimeIntervalSinceReferenceDate:end]];
}
int main() {
    @autoreleasepool {
        const auto resolved=StatisticsInputState::resolved_statistics_intervals;
        auto projection=projectLegacySleepSummary({{3,0,60},{2,60,70},{5,70,130}},resolved);
        assert(projection.complete()&&projection.data()->asleep_segments.size()==1);
        auto result=makeLegacySleepPeriods(projection,@[],true,true,OutputSegment.class,OutputBuilder.class,OutputPeriod.class);
        assert(result.complete()&&result.periods.count==1&&allocatedBuilders==1&&finishes==1);
        OutputPeriod *period=result.periods[0];OutputSegment *segment=period.segments[0];
        assert(segment.category==1&&segment.containsAppleSleepTrackingData&&segment.sampleIntervals.count==2);
        double sum=0;for(NSDateInterval *part in segment.sampleIntervals)sum+=part.duration;
        assert(sum==120&&segment.dateInterval.duration==130); // grouping gap not sleep
        OutputSummary *original=[OutputSummary daySummaryWithMorningIndex:42 dateInterval:interval(-100,200)
            calendar:[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian] periods:@[]
            schedules:@[[NSObject new]] sleepDurationGoal:[NSObject new]];
        auto summary=rebuildLegacyDaySummary(original,result,OutputSummary.class,OutputPeriod.class);
        assert(summary.complete()&&summary.summary!=original);
        OutputSummary *replacement=summary.summary;
        assert(replacement.morningIndex==42&&[replacement.calendar isEqual:original.calendar]&&
               replacement.schedules[0]==original.schedules[0]&&replacement.sleepDurationGoal==original.sleepDurationGoal);
        assert(replacement.periods[0]==result.periods[0]&&original.periods.count==0);
        assert(!rebuildLegacyDaySummary(nil,result,OutputSummary.class,OutputPeriod.class).complete());
        auto empty=projectLegacySleepSummary({{2,0,60}},resolved);
        result=makeLegacySleepPeriods(empty,@[],true,false,OutputSegment.class,OutputBuilder.class,OutputPeriod.class);
        assert(result.complete()&&result.periods.count==0&&allocatedBuilders==1&&finishes==1);
        OutputSegment *inBed=[OutputSegment sleepPeriodSegmentWithDateInterval:interval(-10,150)
            sampleIntervals:@[interval(-10,150)] category:0 containsAppleSleepTrackingData:NO];
        result=makeLegacySleepPeriods(projection,@[inBed],true,true,OutputSegment.class,OutputBuilder.class,OutputPeriod.class);
        assert(result.complete());period=result.periods[0];
        assert(period.segments.count==2&&period.segments[0]==inBed); // unchanged native InBed identity
        auto before=allocatedBuilders;
        result=makeLegacySleepPeriods(projection,@[],false,false,OutputSegment.class,OutputBuilder.class,OutputPeriod.class);
        assert(!result.complete()&&!result.periods&&allocatedBuilders==before);
        factoryFails=YES;
        result=makeLegacySleepPeriods(projection,@[],true,false,OutputSegment.class,OutputBuilder.class,OutputPeriod.class);
        assert(!result.complete()&&!result.periods&&allocatedBuilders==before);factoryFails=NO;
        builderThrows=YES;
        result=makeLegacySleepPeriods(projection,@[],true,false,OutputSegment.class,OutputBuilder.class,OutputPeriod.class);
        assert(result.status==LegacyPeriodStatus::candidate_exception&&!result.periods);builderThrows=NO;
        result=makeLegacySleepPeriods(projection,@[],true,false,OutputSegment.class,OutputBuilder.class,OutputPeriod.class,1,1);
        assert(!result.complete()&&!result.periods);
        result=makeLegacySleepPeriods(projection,@[segment],true,false,OutputSegment.class,OutputBuilder.class,OutputPeriod.class);
        assert(!result.complete()&&!result.periods); // cannot smuggle category1 as native InBed
        result=makeLegacySleepPeriods(empty,@[inBed],true,false,OutputSegment.class,OutputBuilder.class,OutputPeriod.class,10,1);
        assert(result.complete()); // exactly one original InBed interval
        result=makeLegacySleepPeriods(projection,@[inBed],true,false,OutputSegment.class,OutputBuilder.class,OutputPeriod.class,10,2);
        assert(!result.complete()&&!result.periods); // shared budget: 1 InBed + 2 asleep
        for(corruptPeriod=1;corruptPeriod<=4;++corruptPeriod) {
            result=makeLegacySleepPeriods(projection,@[inBed],true,false,OutputSegment.class,OutputBuilder.class,OutputPeriod.class);
            assert(result.status==LegacyPeriodStatus::invalid_native_result&&!result.periods);
        }
        corruptPeriod=0;
        lyingEnvelope=YES;
        result=makeLegacySleepPeriods(projection,@[],true,false,OutputSegment.class,OutputBuilder.class,OutputPeriod.class);
        assert(result.status==LegacyPeriodStatus::invalid_native_result&&!result.periods);lyingEnvelope=NO;
        assert(!ModuleReadiness::may_expand_sleep_acceptance());
        puts("PASS existing segment/period output adapter/derived-only/gap duration/no empty finish");
    }
}
