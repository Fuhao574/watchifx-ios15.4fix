#include "PinnedSleepPendingOrder.hpp"
#include "SleepBucketAdvance.hpp"
#include "StableSleepSeries.hpp"
#include "ModuleReadiness.hpp"
#include <cassert>
#include <cstdio>
#include <limits>

using namespace watchfix::healthsupport;

// Record-shaped reference instantiates the SAME external algorithm, not native
// Apple execution. It verifies index sorting carries whole identities/flags and
// follows the same two-comparator path as moving full records.
struct ReferenceRecord { MappedPendingStage item; std::size_t identity; };
static_assert(std::is_trivially_copy_constructible<ReferenceRecord>::value &&
              std::is_trivially_copy_assignable<ReferenceRecord>::value,
              "Record reference must use the same insertion threshold30");
template<class Compare>
static void referenceSort(std::vector<ReferenceRecord> &records, Compare compare) {
    if (records.empty()) return;
    std::__introsort<std::_ClassicAlgPolicy, Compare &>(records.data(), records.data() + records.size(), compare,
        static_cast<std::ptrdiff_t>(records.size()));
}
static std::size_t rank(std::int64_t id, const std::vector<std::int64_t> &ids) {
    auto found = std::find(ids.begin(), ids.end(), id);
    return static_cast<std::size_t>(found - ids.begin());
}
static void check(std::size_t count, unsigned shape, bool provider) {
    std::vector<MappedPendingStage> items;
    const std::vector<std::int64_t> ids{7, 3, 7, 1};
    for (std::size_t i = 0; i < count; ++i) {
        double start = shape == 0 ? 10 : shape == 1 ? static_cast<double>(i % 7) :
                       shape == 2 ? static_cast<double>(count - i) :
                       static_cast<double>((i * 73 + 19) % 41);
        items.push_back({{{3 + static_cast<std::int64_t>(i % 3), start, start + 10,
                            static_cast<std::int64_t>(i % 11)}, bool(i % 2), bool(i % 3), bool(i % 5)},
                         true, static_cast<std::int64_t>(i % 11), true, static_cast<std::int64_t>(i % 11)});
    }
    auto result = orderSleepPending(items, provider, ids);
    assert(result.complete() && result.permutation()->size() == count);
    std::vector<ReferenceRecord> reference;
    for (std::size_t i = 0; i < count; ++i) reference.push_back({items[i], i});
    if (provider) referenceSort(reference, [&](const ReferenceRecord &a, const ReferenceRecord &b) {
        return rank(a.item.pending.fragment.source_id, ids) < rank(b.item.pending.fragment.source_id, ids);
    });
    referenceSort(reference, [](const ReferenceRecord &a, const ReferenceRecord &b) {
        return a.item.pending.fragment.start < b.item.pending.fragment.start;
    });
    std::vector<bool> seen(count, false);
    for (std::size_t i = 0; i < count; ++i) {
        auto index = (*result.permutation())[i];
        assert(index < count && !seen[index]); seen[index] = true;
        assert(index == reference[i].identity);
        if (i) assert(items[(*result.permutation())[i - 1]].pending.fragment.start <= items[index].pending.fragment.start);
        assert(items[index].pending.history_flag == bool(index % 2));
    }
}
int main() {
    for (std::size_t n : {0u, 1u, 2u, 3u, 4u, 5u, 6u, 29u, 30u, 31u, 999u, 1000u, 1001u, 2048u})
        for (unsigned shape = 0; shape < 4; ++shape) for (bool provider : {false, true}) check(n, shape, provider);
    const std::vector<MappedPendingStage> small{
        {{{3, 0, 45, 8}, false, false, false}, true, 8, true, 8},
        {{{4, 15, 90, 9}, false, false, false}, true, 9, true, 9}
    };
    auto short_order = orderSleepPending(small, true, {9, 8});
    assert(short_order.complete() && (*short_order.permutation())[0] == 0); // second start-sort dominates distinct starts
    auto bad = small; bad[1].pending.fragment.start = std::numeric_limits<double>::quiet_NaN();
    assert(!orderSleepPending(bad, false, {}).permutation());
    assert(!orderSleepPending(small, false, {}, 1).permutation());
    SleepBucketState bucket; bucket.interval_end = 120; bucket.pending = small;
    BucketAdvanceConfiguration config; config.mask_is_empty = true;
    PendingOrdering order = [](const std::vector<MappedPendingStage> &pending) {
        auto sorted = orderSleepPending(pending, true, {8, 9});
        if (!sorted.complete()) throw std::runtime_error("synthetic-order-failure");
        return *sorted.permutation();
    };
    auto advanced = advanceSleepBucket(bucket, 120, config,
        PendingOrderState::native_equivalent_source_then_start_order,
        SourceKeyState::canonicalized_in_one_mapping_session, order);
    assert(advanced.complete() && advanced.data()->state.pending.empty());
    assert(advanced.data()->multi_steps == 2 && advanced.data()->single_steps == 1);
    StableSeriesConfiguration series_configuration;
    series_configuration.bucket.mask_is_empty = true;
    RegisteredPendingOrdering ranked = [](const std::vector<MappedPendingStage> &pending,
                                          const std::vector<std::int64_t> &registered) {
        // Pure fixture ranking source8 before9. No native source manager call.
        auto ranks = registered;
        std::sort(ranks.begin(), ranks.end());
        auto result = orderSleepPending(pending, true, ranks);
        if (!result.complete()) throw std::runtime_error("fixture-pinned-sort-failure");
        return *result.permutation();
    };
    SourceBundleLookup same_bundle{BundleLookupKind::nonnull_bundle, "fixture.same.bundle"};
    std::vector<StableSourceDescription> descriptions{{8, same_bundle}, {9, same_bundle}};
    const std::vector<StageFragment> raw{{3, 0, 100, 8}, {2, 10, 40, 9}, {4, 60, 180, 9}};
    const std::vector<CalendarBucketBounds> calendar{{0, 60}, {60, 120}, {120, 180}};
    auto calculated = calculateStableSleepSeries(raw, calendar, descriptions, true,
        StableSeriesInputState::audited_stable_source_descriptions, series_configuration, ranked);
    assert(calculated.complete() && calculated.data()->buckets.size() == 3);
    assert(calculated.data()->admitted_raw_occurrences == 3);
    double expected_from_decisions = 0;
    for (const auto &interval : calculated.data()->resolved_intervals) {
        assert(interval.category >= 1 && interval.category <= 5);
        if (interval.category != 2) expected_from_decisions += interval.end - interval.start;
    }
    auto projected = projectLegacySleepSummary(calculated.data()->resolved_intervals,
                                                StatisticsInputState::resolved_statistics_intervals);
    assert(projected.complete() && projected.data()->asleep_duration == expected_from_decisions);
    assert(raw[0].category == 3 && raw[1].category == 2 && raw[2].category == 4);
    auto repeated_series = calculateStableSleepSeries(raw, calendar, descriptions, true,
        StableSeriesInputState::audited_stable_source_descriptions, series_configuration, ranked);
    assert(repeated_series.complete() && repeated_series.data()->resolved_intervals.size() == calculated.data()->resolved_intervals.size());
    for (std::size_t i = 0; i < calculated.data()->resolved_intervals.size(); ++i) {
        assert(calculated.data()->resolved_intervals[i].category == repeated_series.data()->resolved_intervals[i].category);
        assert(calculated.data()->resolved_intervals[i].start == repeated_series.data()->resolved_intervals[i].start);
        assert(calculated.data()->resolved_intervals[i].end == repeated_series.data()->resolved_intervals[i].end);
    }
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
    std::puts("PASS pinned pending order/index-record parity/ties/30-1000 thresholds/bucket integration");
}
