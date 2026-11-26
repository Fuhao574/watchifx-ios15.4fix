#include "StableSeriesAdapter.hpp"
#include "ModuleReadiness.hpp"
#include "SleepSampleAdapter.hpp"
#include "LegacyPeriodAdapter.hpp"
#include <cassert>
#include <cstdio>

using namespace watchfix::healthsupport;
static NSUInteger calendarCalls, sourceCalls, rankCalls;
@interface ChainType : NSObject
@property(nonatomic) NSInteger code;
@end
@implementation ChainType @end
@interface ChainSampleSource : NSObject
@property(nonatomic,strong) NSNumber *identifier;
- (NSNumber *)_sourceID;
@end
@implementation ChainSampleSource
- (NSNumber *)_sourceID { return self.identifier; }
@end
@interface ChainRevision : NSObject
@property(nonatomic,strong) id source;
@end
@implementation ChainRevision @end
@interface ChainSample : NSObject
@property(nonatomic) NSInteger value;
@property(nonatomic,strong) id sampleType,sourceRevision;
@property(nonatomic,strong) NSDate *startDate,*endDate;
@end
@implementation ChainSample @end
@interface ChainSegment : NSObject
@property(nonatomic,strong) NSDateInterval *dateInterval;
@property(nonatomic,strong) NSArray *sampleIntervals;
@property(nonatomic) NSInteger category;
@property(nonatomic) BOOL containsAppleSleepTrackingData;
+ (id)sleepPeriodSegmentWithDateInterval:(NSDateInterval *)interval sampleIntervals:(NSArray *)samples
    category:(NSInteger)category containsAppleSleepTrackingData:(BOOL)containsApple;
@end
@implementation ChainSegment
+ (id)sleepPeriodSegmentWithDateInterval:(NSDateInterval *)interval sampleIntervals:(NSArray *)samples
    category:(NSInteger)category containsAppleSleepTrackingData:(BOOL)containsApple {
    ChainSegment *result=[self new];result.dateInterval=interval;result.sampleIntervals=[samples copy];
    result.category=category;result.containsAppleSleepTrackingData=containsApple;return result;
}
@end
@interface ChainPeriod : NSObject
@property(nonatomic,strong) NSDateInterval *dateInterval;
@property(nonatomic,strong) NSArray *segments;
@end
@implementation ChainPeriod @end
@interface ChainPeriodBuilder : NSObject
@property(nonatomic,strong) NSMutableArray *segments;
- (void)addOrderedSegment:(id)segment;
- (NSArray *)finish;
@end
@implementation ChainPeriodBuilder
- (instancetype)init {if((self=[super init]))self.segments=[NSMutableArray array];return self;}
- (void)addOrderedSegment:(id)segment {[self.segments addObject:segment];}
- (NSArray *)finish {
    assert(self.segments.count);ChainPeriod *period=[ChainPeriod new];period.segments=[self.segments copy];
    NSDate *start=nil,*end=nil;
    for(ChainSegment *segment in self.segments) {
        start=start?[start earlierDate:segment.dateInterval.startDate]:segment.dateInterval.startDate;
        end=end?[end laterDate:segment.dateInterval.endDate]:segment.dateInterval.endDate;
    }
    period.dateInterval=[[NSDateInterval alloc]initWithStartDate:start endDate:end];return @[period];
}
@end
@interface SeriesCollection : NSObject
@property(nonatomic,strong) NSArray<NSDateInterval *> *buckets;
- (NSDateInterval *)dateIntervalAtIndex:(int64_t)index;
@end
@implementation SeriesCollection
- (NSDateInterval *)dateIntervalAtIndex:(int64_t)index { ++calendarCalls; return self.buckets[(NSUInteger)index]; }
@end
@interface SeriesSource : NSObject
@property(nonatomic,copy) NSString *bundleIdentifier;
@end
@implementation SeriesSource @end
@interface SeriesProvider : NSObject
@property(nonatomic) BOOL invalidOrder,throwLookup;
@property(nonatomic,strong) id source;
- (NSArray *)orderedSourceIDsWithUnorderedIDs:(NSArray *)ids;
- (id)sourceForSourceID:(int64_t)source;
@end
@implementation SeriesProvider
- (NSArray *)orderedSourceIDsWithUnorderedIDs:(NSArray *)ids {
    ++rankCalls;
    if (self.invalidOrder) return @[@8,@8];
    return [[ids reverseObjectEnumerator] allObjects]; // fixture, not numeric-ID fallback
}
- (id)sourceForSourceID:(int64_t)source {
    (void)source; ++sourceCalls;
    if (self.throwLookup) @throw [NSException exceptionWithName:@"Fixture" reason:nil userInfo:nil];
    return self.source;
}
@end
static NSDateInterval *interval(double start, double end) {
    return [[NSDateInterval alloc] initWithStartDate:[NSDate dateWithTimeIntervalSinceReferenceDate:start]
                                           endDate:[NSDate dateWithTimeIntervalSinceReferenceDate:end]];
}
int main() {
    @autoreleasepool {
        StableSeriesConfiguration config; config.bucket.mask_is_empty = true;
        auto stable = StableSeriesInputState::audited_stable_source_descriptions;
        SeriesCollection *collection = [SeriesCollection new];
        collection.buckets = @[interval(0,60),interval(60,120),interval(120,180)];
        SeriesProvider *provider = [SeriesProvider new];
        SeriesSource *source = [SeriesSource new]; source.bundleIdentifier = @"fixture.same.bundle";
        provider.source = source;
        const std::vector<StageFragment> raw{{3,0,100,8},{2,10,40,9},{4,60,180,9}};
        auto result = calculateStableSleepSeriesWithAdapters(raw,collection,SeriesCollection.class,0,3,
                                                               provider,SeriesProvider.class,stable,config);
        assert(result.complete() && result.series.data()->buckets.size() == 3);
        assert(calendarCalls == 3 && sourceCalls == 2 && rankCalls > 0);
        auto projection = projectLegacySleepSummary(result.series.data()->resolved_intervals,
                                                      StatisticsInputState::resolved_statistics_intervals);
        assert(projection.complete() && projection.data()->asleep_duration > 0);
        assert(raw[0].category == 3 && raw[1].category == 2 && raw[2].category == 4);
        NSMutableArray *sampleObjects=[NSMutableArray array];
        for(const auto &fragment:raw) {
            ChainSample *sample=[ChainSample new];ChainType *type=[ChainType new];type.code=63;
            ChainSampleSource *sourceObject=[ChainSampleSource new];sourceObject.identifier=@(fragment.source_id);
            ChainRevision *revision=[ChainRevision new];revision.source=sourceObject;
            sample.sampleType=type;sample.sourceRevision=revision;sample.value=fragment.category;
            sample.startDate=[NSDate dateWithTimeIntervalSinceReferenceDate:fragment.start];
            sample.endDate=[NSDate dateWithTimeIntervalSinceReferenceDate:fragment.end];[sampleObjects addObject:sample];
        }
        auto input=readSleepSampleSnapshot(sampleObjects,ChainSample.class,ChainType.class,ChainRevision.class,ChainSampleSource.class);
        assert(input.complete()&&input.non_in_bed.size()==raw.size()&&input.original_in_bed.count==0);
        auto fromObjects=calculateStableSleepSeriesWithAdapters(input.non_in_bed,collection,SeriesCollection.class,0,3,
                                                                 provider,SeriesProvider.class,stable,config);
        assert(fromObjects.complete());
        auto projected=projectLegacySleepSummary(fromObjects.series.data()->resolved_intervals,
                                                   StatisticsInputState::resolved_statistics_intervals);
        assert(projected.complete());
        auto output=makeLegacySleepPeriods(projected,@[],true,true,ChainSegment.class,ChainPeriodBuilder.class,ChainPeriod.class);
        assert(output.complete()&&output.periods.count==1);
        ChainPeriod *period=output.periods[0];double outputDuration=0;
        for(ChainSegment *segment in period.segments) {
            assert(segment.category==1&&segment.containsAppleSleepTrackingData);
            for(NSDateInterval *part in segment.sampleIntervals)outputDuration+=part.duration;
        }
        assert(outputDuration==projected.data()->asleep_duration);
        assert(((ChainSample *)sampleObjects[0]).value==3&&((ChainSample *)sampleObjects[1]).value==2&&
               ((ChainSample *)sampleObjects[2]).value==4);
        auto lookupsBefore=sourceCalls;
        const auto ranksBefore=rankCalls;
        auto consumed=calculateConsumptionSleepSeriesWithAdapters(input.non_in_bed,collection,SeriesCollection.class,0,3,
            provider,SeriesProvider.class,StableSeriesInputState::audited_consumption_point_callbacks,config);
        assert(consumed.complete()&&sourceCalls>lookupsBefore+2); // fresh source cache each bucket
        assert(rankCalls==ranksBefore+2); // one refresh per two-source bucket; final bucket single
        auto consumedProjection=projectLegacySleepSummary(consumed.series.data()->resolved_intervals,
            StatisticsInputState::resolved_statistics_intervals);
        assert(consumedProjection.complete()&&consumedProjection.data()->asleep_duration==projected.data()->asleep_duration);
        provider.source=nil;lookupsBefore=sourceCalls;
        consumed=calculateConsumptionSleepSeriesWithAdapters(input.non_in_bed,collection,SeriesCollection.class,0,3,
            provider,SeriesProvider.class,StableSeriesInputState::audited_consumption_point_callbacks,config);
        assert(consumed.complete()&&sourceCalls>lookupsBefore+2); // actual nil relookup, not frozen nil description
        provider.source=source;
        provider.invalidOrder = YES;
        auto failure = calculateStableSleepSeriesWithAdapters(raw,collection,SeriesCollection.class,0,3,
                                                                provider,SeriesProvider.class,stable,config);
        assert(!failure.complete() && !failure.series.data());
        provider.invalidOrder = NO; provider.throwLookup = YES;
        failure = calculateStableSleepSeriesWithAdapters(raw,collection,SeriesCollection.class,0,3,
                                                          provider,SeriesProvider.class,stable,config);
        assert(failure.status == StableAdapterStatus::source_lookup_failed && !failure.series.data());
        provider.throwLookup = NO;
        auto absent = calculateStableSleepSeriesWithAdapters(raw,collection,SeriesCollection.class,0,3,
                                                               nil,Nil,stable,config);
        assert(absent.complete());
        auto before = calendarCalls;
        failure = calculateStableSleepSeriesWithAdapters({{6,0,60,8}},collection,SeriesCollection.class,0,3,
                                                          provider,SeriesProvider.class,stable,config);
        assert(failure.status == StableAdapterStatus::invalid_sample && calendarCalls == before);
        failure = calculateStableSleepSeriesWithAdapters({{3,10,60,8},{4,0,60,9}},collection,SeriesCollection.class,0,3,
                                                          provider,SeriesProvider.class,stable,config);
        assert(failure.status == StableAdapterStatus::unordered_samples && calendarCalls == before);
        failure = calculateStableSleepSeriesWithAdapters(raw,collection,SeriesCollection.class,0,3,
            provider,SeriesProvider.class,StableSeriesInputState::unresolved_native_input,config);
        assert(!failure.complete() && calendarCalls == before);
        config.bucket.mask_is_empty = false;
        failure = calculateStableSleepSeriesWithAdapters(raw,collection,SeriesCollection.class,0,3,
                                                          provider,SeriesProvider.class,stable,config);
        assert(failure.status == StableAdapterStatus::invalid_configuration && calendarCalls == before);
        assert(!ModuleReadiness::may_expand_sleep_acceptance());
        puts("PASS stable calendar/provider/sort/series/legacy integration/failure closed/no HealthKit");
        puts("PASS sample getter objects to existing period factory signatures/raw untouched");
    }
}
