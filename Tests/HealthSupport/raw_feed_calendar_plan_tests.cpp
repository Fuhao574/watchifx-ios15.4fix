#include "RawFeedCalendarPlan.hpp"
#include "ConsumptionSleepSeries.hpp"
#include <cassert>
#include <cstdio>
using namespace watchfix::healthsupport;
static IndexedCalendarBucket at(std::int64_t index) {
    IndexedCalendarBucket result;result.resolved=true;result.index=index;result.bounds={double(index*60),double((index+1)*60)};return result;
}
static IndexedCalendarBucket containing(double time){return at(static_cast<std::int64_t>(std::floor(time/60)));}
int main() {
    auto plan=[](const std::vector<StageFragment>&raw){return RawFeedCalendarPlan::calculate(raw,containing,at,100,100,100);};
    assert(plan({}).buckets()->empty());
    auto p=plan({{3,10,120,8}});assert(p.buckets()&&p.buckets()->size()==2&&p.buckets()->front().index==0&&p.buckets()->back().index==1);
    p=plan({{3,-10,10,8}});assert(p.buckets()&&p.buckets()->size()==2&&p.buckets()->front().index==-1);
    p=plan({{3,10,20,8},{4,180,190,8}});assert(p.buckets()&&p.buckets()->size()==2&&p.buckets()->back().index==3); // jump, not blank intermediate buckets
    p=plan({{3,0,60.005,8}});assert(p.buckets()&&p.buckets()->size()==1); // tiny right dropped, no ceil(end)+1
    p=plan({{3,59.995,60.005,8}});assert(p.buckets()&&p.buckets()->size()==2); // whole raw carry retained, no intersection
    p=plan({{3,0,180,8},{4,15,90,9}});assert(p.buckets()&&p.buckets()->size()==3);
    assert(!RawFeedCalendarPlan::calculate({{3,0,180,8}},containing,at,100,1,100).buckets());
    StableSeriesConfiguration config;config.bucket.mask_is_empty=true;config.raw_feed_calendar_routing=true;
    auto missing=calculateConsumptionSleepSeries({{3,10,20,8},{4,100,110,8}},{{0,60},{180,240}},
        StableSeriesInputState::audited_consumption_point_callbacks,config,{},[]{return false;},{});
    assert(missing.status()==StableSeriesStatus::sample_outside_supplied_range&&!missing.data());
    for(const auto &raw:std::vector<std::vector<StageFragment>>{
        {{3,10,120,8}},{{3,-10,10,8}},{{3,10,20,8},{4,180,190,8}},{{3,0,60.005,8}}}) {
        auto planned=plan(raw);assert(planned.buckets());std::vector<CalendarBucketBounds> bounds;
        for(const auto &bucket:*planned.buckets())bounds.push_back(bucket.bounds);
        auto series=calculateConsumptionSleepSeries(raw,bounds,StableSeriesInputState::audited_consumption_point_callbacks,
            config,{},[]{return false;},{});
        assert(series.complete()&&series.data()->buckets.size()==bounds.size());
        assert(raw.front().category==3);
    }
    std::puts("PASS first-raw calendar routing/raw-carry finish/no day hull/no extra tail/empty-span jump/0.01 whole-side");
}
