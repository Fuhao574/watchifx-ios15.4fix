#include "StableSleepSeries.hpp"
#include "ModuleReadiness.hpp"
#include <cassert>
#include <cstdio>

using namespace watchfix::healthsupport;
int main() {
    StableSeriesConfiguration configuration; configuration.bucket.mask_is_empty = true;
    const auto stable = StableSeriesInputState::audited_stable_source_descriptions;
    RegisteredPendingOrdering fixture_order = [](const std::vector<MappedPendingStage> &pending,
                                                  const std::vector<std::int64_t> &) {
        // Explicit small fixtures only. General audited sorting is tested in
        // pinned_pending_order_tests.cpp, never inferred from this permutation.
        std::vector<std::size_t> indices;
        for (std::size_t i = 0; i < pending.size(); ++i) indices.push_back(i);
        return indices;
    };
    SourceBundleLookup bundle{BundleLookupKind::nonnull_bundle, "fixture.bundle"};
    const std::vector<StableSourceDescription> sources{{8, bundle}, {9, {BundleLookupKind::nil_bundle, {}}}};
    const std::vector<CalendarBucketBounds> bounds{{0, 60}, {60, 120}, {120, 180}};
    const std::vector<StageFragment> inputs{{3, 0, 180, 8}};
    auto series = calculateStableSleepSeries(inputs, bounds, sources, true, stable, configuration, fixture_order);
    assert(series.complete() && series.data()->buckets.size() == 3);
    assert(series.data()->resolved_intervals.size() == 3 && series.data()->admitted_raw_occurrences == 1);
    auto summary = projectLegacySleepSummary(series.data()->resolved_intervals, StatisticsInputState::resolved_statistics_intervals);
    assert(summary.complete() && summary.data()->asleep_duration == 180 && summary.data()->asleep_segments.size() == 1);
    assert(inputs[0].category == 3 && inputs[0].end == 180);
    auto awake = calculateStableSleepSeries({{2, 0, 180, 8}}, bounds, sources, true, stable, configuration, fixture_order);
    assert(awake.complete() && awake.data()->resolved_intervals.size() == 3);
    assert(projectLegacySleepSummary(awake.data()->resolved_intervals, StatisticsInputState::resolved_statistics_intervals).data()->asleep_duration == 0);
    auto empty = calculateStableSleepSeries({}, bounds, {}, false, stable, configuration, fixture_order);
    assert(empty.complete() && empty.data()->buckets.size() == 3 && empty.data()->resolved_intervals.empty());
    auto disjoint = calculateStableSleepSeries({{3, 0, 60, 8}, {5, 120, 180, 9}}, bounds, sources, true,
                                               stable, configuration, fixture_order);
    assert(disjoint.complete() && disjoint.data()->resolved_intervals.size() == 2);
    assert(projectLegacySleepSummary(disjoint.data()->resolved_intervals, StatisticsInputState::resolved_statistics_intervals).data()->asleep_duration == 120);
    auto mixed = calculateStableSleepSeries({{3, 0, 45, 8}, {4, 15, 90, 9}}, {{0, 120}}, sources, true,
                                            stable, configuration, fixture_order);
    assert(mixed.complete() && mixed.data()->resolved_intervals.size() == 1);
    assert(mixed.data()->resolved_intervals[0].category == 3);
    auto absent_provider = calculateStableSleepSeries(inputs, bounds, {}, false, stable, configuration, fixture_order);
    assert(absent_provider.complete());
    auto nonuniform = calculateStableSleepSeries({{4, 0, 181, 8}}, {{0, 61}, {61, 121}, {121, 181}}, sources,
                                                  true, stable, configuration, fixture_order);
    assert(nonuniform.complete() && nonuniform.data()->resolved_intervals[0].end == 61);
    assert(!calculateStableSleepSeries(inputs, bounds, sources, true, StableSeriesInputState::unresolved_native_input,
                                       configuration, fixture_order).data());
    assert(calculateStableSleepSeries(inputs, bounds, {}, true, stable, configuration, fixture_order).status() == StableSeriesStatus::missing_source_description);
    assert(!calculateStableSleepSeries({{3, 120, 180, 8}, {4, 0, 60, 8}}, bounds, sources, true, stable, configuration, fixture_order).data());
    assert(!calculateStableSleepSeries(inputs, {{0, 60}, {61, 180}}, sources, true, stable, configuration, fixture_order).data());
    assert(calculateStableSleepSeries({{3, 0, 181, 8}}, bounds, sources, true, stable, configuration, fixture_order).status() == StableSeriesStatus::sample_outside_supplied_range);
    assert(!calculateStableSleepSeries({{0, 0, 60, 8}}, bounds, sources, true, stable, configuration, fixture_order).data());
    assert(!calculateStableSleepSeries(inputs, bounds, {{8, {}}}, true, stable, configuration, fixture_order).data());
    assert(!calculateStableSleepSeries(inputs, bounds, {{8, bundle}, {8, bundle}}, true, stable, configuration, fixture_order).data());
    auto limited = configuration; limited.maximum_buckets = 1;
    assert(!calculateStableSleepSeries(inputs, bounds, sources, true, stable, limited, fixture_order).data());
    limited = configuration; limited.maximum_bundle_bytes = 1;
    assert(!calculateStableSleepSeries(inputs, bounds, sources, true, stable, limited, fixture_order).data());
    limited = configuration; limited.bucket.mask_is_empty = false;
    assert(!calculateStableSleepSeries(inputs, bounds, sources, true, stable, limited, fixture_order).data());
    auto sort_failed = calculateStableSleepSeries({{3, 0, 45, 8}, {4, 15, 90, 9}}, {{0, 120}}, sources,
                                                  true, stable, configuration, {});
    assert(!sort_failed.complete() && !sort_failed.data());
    auto numeric_zero = configuration;
    numeric_zero.bucket_end_split_order = SplitOrder::numeric_zero;
    for (const auto &ranges : std::vector<std::vector<CalendarBucketBounds>>{
        {{0, 60}}, {{0, 60}, {60, 120}}}) {
        auto residual = calculateStableSleepSeries({{3, 59.995, 60, 8}}, ranges, sources,
                                                    true, stable, numeric_zero, fixture_order);
        assert(residual.status() == StableSeriesStatus::unconsumed_tail && !residual.data());
    }
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
    std::puts("PASS stable-source series/raw admission/multi-bucket carry/whole-bucket projection/no runtime");
}
