#include "DayStatisticsAdapter.hpp"
#import "RuntimeTypeChecks.h"
#include "RawFeedCalendarPlan.hpp"
@protocol WFHSRawFeedIntervals
- (NSDateInterval *)dateIntervalContainingDate:(NSDate *)date index:(int64_t *)index;
- (NSDateInterval *)dateIntervalAtIndex:(int64_t)index;
@end
namespace watchfix { namespace healthsupport {
namespace {
IndexedCalendarBucket readBucket(id interval,std::int64_t index) {
    IndexedCalendarBucket bucket;
    if(!WFHSActuallyInheritsFrom(interval,NSDateInterval.class)||index==INT64_MIN)return bucket;
    id s=[interval startDate],e=[interval endDate];
    if(!WFHSActuallyInheritsFrom(s,NSDate.class)||!WFHSActuallyInheritsFrom(e,NSDate.class))return bucket;
    bucket.index=index;bucket.bounds={[s timeIntervalSinceReferenceDate],[e timeIntervalSinceReferenceDate]};
    bucket.resolved=true;return bucket;
}
bool dayPreflight(const std::vector<StageFragment> &raw,NSInteger seconds,
    const StableSeriesConfiguration &config,const ProjectionConfiguration &projection) {
    if(seconds<=0||seconds>86400||!config.maximum_samples||!config.maximum_buckets||
       !config.maximum_bundle_bytes||!config.maximum_total_bundle_bytes||!config.bucket.maximum_keys||
       !config.bucket.maximum_pending||!config.bucket.maximum_steps||!config.bucket.mask_is_empty||
       !std::isfinite(config.bucket.merge_granularity)||config.bucket.merge_granularity<=0||
       config.bucket_end_split_order!=SplitOrder::numeric_one||!projection.maximum_intervals||
       !std::isfinite(projection.maximum_combination_gap)||projection.maximum_combination_gap<0||
       raw.size()>config.maximum_samples)return false;
    for(std::size_t i=0;i<raw.size();++i) {
        const auto &sample=raw[i];
        if(sample.category<1||sample.category>5||!std::isfinite(sample.start)||!std::isfinite(sample.end)||
           sample.end<=sample.start||!std::isfinite(sample.end-sample.start)||(i&&sample.start<raw[i-1].start))return false;
    }
    return true;
}
}
LegacyProjection calculateBoundDayStatistics(const std::vector<StageFragment> &raw,
    WFHSDaySnapshot *snapshot,WFHSBoundDayContext *context,id provider,
    const DayStatisticsFactories &factories,NSInteger bucket_seconds,
    const StableSeriesConfiguration &configuration,ProjectionConfiguration projection) {
    // A default incomplete projection is explicit failure, not complete zero.
    if(!snapshot||!context||!dayPreflight(raw,bucket_seconds,configuration,projection)||!factories.date||!factories.calendar||
       !factories.collection||!factories.cache||(provider&&!factories.provider))return {};
    try {
        @try {
            if(snapshot.status!=WFHSDaySnapshotComplete||!context.profile||context.calendarCache!=snapshot.calendarCache)return {};
            if(!WFHSActuallyInheritsFrom(snapshot.dateInterval,NSDateInterval.class))return {};
            if(raw.empty())return projectLegacySleepSummary({},StatisticsInputState::resolved_statistics_intervals,projection);
            const double start=raw.front().start;
            // Bootstrap only the first sample's start bucket. The range planner
            // below, NOT day hull/maxEnd rounding, chooses all later buckets.
            auto calendar=WFHSCreateSleepCalendarForFirstSample(snapshot.morningIndex,snapshot.calendarCache,
                factories.cache,factories.date,factories.calendar,factories.collection,bucket_seconds,
                [NSDate dateWithTimeIntervalSinceReferenceDate:start]);
            if(!calendar||calendar.status!=WFHSSleepCalendarComplete||!calendar.intervals.count)return {};
            bool first_lookup=true;
            auto plan=RawFeedCalendarPlan::calculate(raw,[&](double time) {
                if(first_lookup) {
                    first_lookup=false;
                    return readBucket(calendar.intervals[0],calendar.firstIndex);
                }
                int64_t index=INT64_MIN;
                id interval=[(id<WFHSRawFeedIntervals>)calendar.collection dateIntervalContainingDate:
                    [NSDate dateWithTimeIntervalSinceReferenceDate:time] index:&index];
                return readBucket(interval,index);
            },[&](std::int64_t index) {
                return readBucket([(id<WFHSRawFeedIntervals>)calendar.collection dateIntervalAtIndex:index],index);
            },configuration.maximum_samples,configuration.maximum_buckets,configuration.bucket.maximum_pending);
            if(!plan.buckets())return {};
            std::vector<CalendarBucketBounds> bounds;
            for(const auto &bucket:*plan.buckets())bounds.push_back(bucket.bounds);
            auto routed=configuration;routed.raw_feed_calendar_routing=true;
            auto series=calculateConsumptionSleepBoundsWithAdapters(raw,bounds,provider,factories.provider,
                StableSeriesInputState::audited_consumption_point_callbacks,routed);
            if(!series.complete())return {};
            return projectLegacySleepSummary(series.series.data()->resolved_intervals,
                StatisticsInputState::resolved_statistics_intervals,projection);
        } @catch(NSException *candidateException) {(void)candidateException;return {};}
    } catch(...) {return {};}
}
LegacyProjection calculateBoundDayStatisticsUsingProfile(const std::vector<StageFragment> &raw,
    WFHSDaySnapshot *snapshot,WFHSBoundDayContext *context,id actual_sleep_category,
    const DayProfileClasses &profile_classes,const DayStatisticsFactories &factories,
    NSInteger bucket_seconds,const StableSeriesConfiguration &configuration,ProjectionConfiguration projection) {
    if(!snapshot||!context||!dayPreflight(raw,bucket_seconds,configuration,projection))return {};
    try {
    @try {
        // Per-query provider holds profile weakly; this synchronous attempt owns
        // a temporary strong profile exactly while constructing/consuming it.
        __attribute__((objc_precise_lifetime)) id profile=context.profile;
        if(!profile||!snapshot||context.calendarCache!=snapshot.calendarCache)return {};
        WFHSProfileSleepSourceProvider *provider=[[WFHSProfileSleepSourceProvider alloc]
            initWithProfile:profile profileClass:profile_classes.profile sleepCategory:actual_sleep_category
            categoryClass:profile_classes.category sourceOrderManagerClass:profile_classes.source_order_manager
            sourceManagerClass:profile_classes.source_manager maximumSources:configuration.bucket.maximum_keys];
        if(!provider)return {};
        auto supplied=factories;supplied.provider=WFHSProfileSleepSourceProvider.class;
        return calculateBoundDayStatistics(raw,snapshot,context,provider,supplied,bucket_seconds,configuration,projection);
    } @catch(NSException *candidateException) {(void)candidateException;return {};}
    } catch(...) {return {};}
}
} }
