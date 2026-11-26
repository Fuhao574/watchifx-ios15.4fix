#include "ConsumptionSleepSeries.hpp"
#include "ModuleReadiness.hpp"
#include <cassert>
#include <cstdio>
using namespace watchfix::healthsupport;

int main() {
    StableSeriesConfiguration config; config.bucket.mask_is_empty = true;
    const auto dynamic = StableSeriesInputState::audited_consumption_point_callbacks;
    std::size_t calls = 0;
    std::vector<std::int64_t> queried;
    auto lookup = [&](std::int64_t source) {
        ++calls; queried.push_back(source);
        return SourceBundleLookup{BundleLookupKind::nonnull_bundle,"same.bundle"};
    };
    RegisteredPendingOrdering order = [](const std::vector<MappedPendingStage> &pending,
                                         const std::vector<std::int64_t> &) {
        std::vector<std::size_t> result; for(std::size_t i=0;i<pending.size();++i)result.push_back(i);return result;
    }; // fixture only, production ordering still separate
    const std::vector<StageFragment> input{{3,0,120,8},{4,15,90,9}};
    auto result = calculateConsumptionSleepSeries(input,{{0,60},{60,120}},dynamic,config,order,
                                                   []{return true;},lookup);
    assert(result.complete()&&result.data()->buckets.size()==2&&result.data()->admitted_raw_occurrences==2);
    assert(calls==4); // nonnil cached per bucket, NOT one frozen source map per query
    assert((queried==std::vector<std::int64_t>{8,9,8,9}));
    auto summary=projectLegacySleepSummary(result.data()->resolved_intervals,StatisticsInputState::resolved_statistics_intervals);
    assert(summary.complete()&&summary.data()->asleep_duration==120);
    assert(input[0].category==3&&input[1].category==4);
    // Reject malformed entire input before creating sessions or doing lookups.
    auto prior=calls;
    auto invalid=calculateConsumptionSleepSeries({{6,0,60,8}},{{0,60}},dynamic,config,order,[]{return true;},lookup);
    assert(!invalid.complete()&&calls==prior);
    calls=0;
    auto nils = [&](std::int64_t) { ++calls; return SourceBundleLookup{BundleLookupKind::nil_bundle,{}}; };
    result=calculateConsumptionSleepSeries(input,{{0,60},{60,120}},dynamic,config,order,[]{return true;},nils);
    assert(result.complete()&&calls>4); // admission AND actual consumption relookup
    calls=0; bool provider=true;
    auto disappears = [&](std::int64_t source) {
        ++calls;if(source==9)provider=false;
        return SourceBundleLookup{BundleLookupKind::nonnull_bundle,"fixture.bundle"};
    };
    result=calculateConsumptionSleepSeries(input,{{0,60},{60,120}},dynamic,config,order,[&]{return provider;},disappears);
    assert(result.complete()&&calls==2); // absent later, no whole-query presence freeze
    result=calculateConsumptionSleepSeries(input,{{0,60},{60,120}},dynamic,config,order,[]{return true;},
        [](std::int64_t)->SourceBundleLookup{return {};});
    assert(!result.complete()&&!result.data());
    // A later bucket's lookup failure must not expose the already finished
    // first bucket, or reuse that bucket's nonnil source cache.
    calls=0;
    result=calculateConsumptionSleepSeries({{3,0,120,8}},{{0,60},{60,120}},dynamic,config,order,
        []{return true;},[&](std::int64_t) {
            ++calls;return calls==1?SourceBundleLookup{BundleLookupKind::nonnull_bundle,"first.bucket"}:SourceBundleLookup{};
        });
    assert(!result.complete()&&!result.data()&&calls==2);
    auto budget=config;budget.maximum_bundle_bytes=1;budget.maximum_total_bundle_bytes=1;
    calls=0;
    result=calculateConsumptionSleepSeries({{3,0,120,8}},{{0,60},{60,120}},dynamic,budget,order,
        []{return true;},[&](std::int64_t) {++calls;return SourceBundleLookup{BundleLookupKind::nonnull_bundle,"x"};});
    assert(!result.complete()&&!result.data()&&calls==2); // whole-series, not renewed each bucket
    budget.maximum_total_bundle_bytes=2;
    result=calculateConsumptionSleepSeries({{3,0,120,8}},{{0,60},{60,120}},dynamic,budget,order,
        []{return true;},[](std::int64_t) {return SourceBundleLookup{BundleLookupKind::nonnull_bundle,"x"};});
    assert(result.complete());
    // Verify which session owns each actual key call, not merely lookup counts.
    std::size_t generation=0;
    std::vector<std::string> events;
    SeriesSourceSessionFactory sessions=[&] {
        const auto id=++generation;
        struct Owner {
            std::size_t id;std::vector<std::string> *events;
            Owner(std::size_t i,std::vector<std::string> *e):id(i),events(e){}
            ~Owner(){events->push_back("drop"+std::to_string(id));}
        };
        SeriesSourceSession session;session.owner=std::make_shared<Owner>(id,&events);
        auto key=[&,id](std::int64_t) {
            events.push_back("key"+std::to_string(id));ConsumptionKey value;value.resolved=true;value.key=id;return value;
        };
        session.consumption.key=key;
        session.identity=[key](std::int64_t source) {
            auto keyResult=key(source);AdmissionSourceIdentity value;value.resolved=keyResult.resolved;
            value.ledger_key=keyResult.key;return value;
        };
        return session;
    };
    result=calculateStableSleepSeries({{3,0,120,8}},{{0,60},{60,120}}, {}, false,dynamic,config,order,&sessions);
    assert(result.complete());
    // Admission old key, old finish key, next carry admission key, old owner
    // retirement, next final key, next owner retirement. No map moved early.
    assert((events==std::vector<std::string>{"key1","key1","key2","drop1","key2","drop2"}));
    auto unresolved=calculateConsumptionSleepSeries(input,{{0,60},{60,120}},
        StableSeriesInputState::audited_stable_source_descriptions,config,order,[]{return true;},lookup);
    assert(!unresolved.complete());
    config.bucket_end_split_order=SplitOrder::numeric_zero;
    auto tail=calculateConsumptionSleepSeries({{3,59.995,60,8}},{{0,60},{60,120}},dynamic,config,order,
                                               []{return false;},{});
    assert(tail.status()==StableSeriesStatus::unconsumed_tail&&!tail.data());
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
    std::puts("PASS consumption-point multi-bucket/fresh mapping lifetime/nil relookup/no source prefetch/no runtime");
}
