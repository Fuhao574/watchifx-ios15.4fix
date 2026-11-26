#ifndef WFHS_DAY_STATISTICS_ADAPTER_HPP
#define WFHS_DAY_STATISTICS_ADAPTER_HPP
#include "DaySummaryAdapter.hpp"
#include "StableSeriesAdapter.hpp"
#import "SleepCalendarContext.h"
#import "ProfileSleepSourceProvider.h"
namespace watchfix { namespace healthsupport {
// Exact native factory objects/classes are supplied by verified runtime context,
// not discovered here. Provider is borrowed strongly through the synchronous
// call only. Native caller/ownership/readiness checks remain separate.
// Fixed scope: strategy0, no source-key overrides, empty mask, native collection
// end split numeric1, advance-before-enqueue. Routing now follows first raw.start,
// valid raw carry and empty-carry calendar jumps, NOT a day hull/maxEnd heuristic.
// Calendar calls are preplanned under stable-value/nonconcurrent prerequisites;
// this still doesn't prove all native query/copy/output semantics. Raw isn't clipped.
struct DayStatisticsFactories {
    Class date = Nil, calendar = Nil, collection = Nil, cache = Nil, provider = Nil;
};
struct DayProfileClasses {
    Class profile = Nil, category = Nil, source_order_manager = Nil, source_manager = Nil;
};
LegacyProjection calculateBoundDayStatistics(const std::vector<StageFragment> &raw,
    WFHSDaySnapshot *snapshot, WFHSBoundDayContext *context, id provider,
    const DayStatisticsFactories &factories, NSInteger bucket_seconds,
    const StableSeriesConfiguration &configuration, ProjectionConfiguration projection = {});
LegacyProjection calculateBoundDayStatisticsUsingProfile(const std::vector<StageFragment> &raw,
    WFHSDaySnapshot *snapshot, WFHSBoundDayContext *context, id actual_sleep_category,
    const DayProfileClasses &profile_classes, const DayStatisticsFactories &factories,
    NSInteger bucket_seconds, const StableSeriesConfiguration &configuration, ProjectionConfiguration projection = {});
} }
#endif
