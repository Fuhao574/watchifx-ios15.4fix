#include "SleepBucketRollover.hpp"
#include "SleepStatisticsBucketOutput.hpp"
#include "SleepSourceIdentityMap.hpp"
#include "ModuleReadiness.hpp"
#include <cassert>
#include <cstdio>

using namespace watchfix::healthsupport;
static BucketLifecycleState fresh(double start, double end) {
    BucketLifecycleState state{{start, end}, {}, {}, {}};
    state.statistics.current = start; state.statistics.interval_end = end;
    return state;
}
int main() {
    const auto ordered = PendingOrderState::native_equivalent_source_then_start_order;
    const auto mapped = SourceKeyState::canonicalized_in_one_mapping_session;
    BucketAdvanceConfiguration config; config.mask_is_empty = true;
    RegisteredPendingOrdering order = [](const std::vector<MappedPendingStage> &pending, const std::vector<std::int64_t> &) {
        std::vector<std::size_t> indices; for (std::size_t i = 0; i < pending.size(); ++i) indices.push_back(i);
        return indices; // Fixture order only, native adapter tested separately.
    };
    std::size_t lookups = 0;
    AdmissionIdentity identity = [&](std::int64_t source) {
        ++lookups; AdmissionSourceIdentity result; result.resolved = true;
        result.ledger_key = source; result.has_bundle_group = true; result.bundle_group = source; return result;
    };
    auto initial = admitRawStageToBucket(fresh(0, 60), {4, 0, 180, 8}, true, SplitOrder::numeric_one,
                                          config, ordered, mapped, order, identity);
    assert(initial.complete() && initial.state()->raw_carry.size() == 1);
    auto first = rolloverSleepBucket(*initial.state(), {60, 120}, SplitOrder::numeric_one,
                                      config, ordered, mapped, order, identity);
    assert(first.complete() && first.data()->replayed_raw_fragments == 1);
    assert(first.data()->finished_previous.current == 60);
    assert(first.data()->next.statistics.current == 60);
    assert(!first.data()->next.statistics.total.decision().has_stage);
    assert(first.data()->next.statistics.ledger.find(8) && !first.data()->next.statistics.ledger.find(8)->decision().has_stage);
    const auto &pending = first.data()->next.statistics.pending.front().pending;
    assert(!pending.history_flag && !pending.per_source_counted && !pending.total_counted);
    assert(pending.fragment.start == 60 && pending.fragment.end == 120);
    assert(first.data()->next.raw_carry[0].start == 120 && first.data()->next.raw_carry[0].end == 180);
    auto second = rolloverSleepBucket(first.data()->next, {120, 180}, SplitOrder::numeric_one,
                                       config, ordered, mapped, order, identity);
    assert(second.complete() && second.data()->next.raw_carry.empty() && lookups == 3);
    auto final = advanceSleepBucket(second.data()->next.statistics, 180, config, ordered, mapped, {});
    assert(final.complete() && final.data()->state.pending.empty());
    auto a = finalizeSleepStatisticsBucket(first.data()->finished_previous.total, {0, 60}, true);
    auto b = finalizeSleepStatisticsBucket(second.data()->finished_previous.total, {60, 120}, true);
    auto c = finalizeSleepStatisticsBucket(final.data()->state.total, {120, 180}, true);
    assert(a.succeeded() && b.succeeded() && c.succeeded() && a.interval() && b.interval() && c.interval());
    auto projected = projectLegacySleepSummary({*a.interval(), *b.interval(), *c.interval()},
                                                StatisticsInputState::resolved_statistics_intervals);
    assert(projected.complete() && projected.data()->asleep_duration == 180 && projected.data()->asleep_segments.size() == 1);
    assert(initial.state()->statistics.current == 0 && initial.state()->raw_carry[0].start == 60);

    // Old bucket current can overshoot; next raw carry is independent and must
    // still replay starting at calendar boundary45, not old current60.
    auto overrun = fresh(0, 45);
    auto over_a = admitRawStageToBucket(overrun, {3, 0, 100, 8}, false, SplitOrder::numeric_one,
                                         config, ordered, mapped, order, identity);
    assert(over_a.complete());
    auto over_b = admitRawStageToBucket(*over_a.state(), {5, 1, 90, 9}, false, SplitOrder::numeric_one,
                                         config, ordered, mapped, order, identity);
    assert(over_b.complete());
    auto moved = rolloverSleepBucket(*over_b.state(), {45, 105}, SplitOrder::numeric_one,
                                      config, ordered, mapped, order, identity);
    assert(moved.complete() && moved.data()->finished_previous.current == 60);
    assert(moved.data()->next.statistics.current == 45 && moved.data()->next.statistics.pending.size() == 2);
    assert(moved.data()->next.statistics.pending[0].pending.fragment.start == 45);
    assert(!moved.data()->next.statistics.pending[0].pending.total_counted);

    // Threshold whole-carry can start slightly before the next bucket. No clamp.
    auto tiny = admitRawStageToBucket(fresh(0, 60), {3, 59.995, 60.005, 8}, false, SplitOrder::numeric_one,
                                       config, ordered, mapped, order, identity);
    assert(tiny.complete() && tiny.state()->statistics.pending.empty());
    auto tiny_next = rolloverSleepBucket(*tiny.state(), {60, 120}, SplitOrder::numeric_one,
                                          config, ordered, mapped, order, identity);
    assert(tiny_next.complete() && tiny_next.data()->next.statistics.current == 60);
    assert(tiny_next.data()->next.statistics.pending[0].pending.fragment.start == 59.995);

    auto failed = rolloverSleepBucket(*initial.state(), {60, 120}, SplitOrder::numeric_one,
                                       config, ordered, mapped, order, {});
    assert(failed.status() == BucketRolloverStatus::carry_admission_failed && !failed.data());
    assert(initial.state()->statistics.current == 0); // no partial previous/next published
    assert(!rolloverSleepBucket(*initial.state(), {61, 120}, SplitOrder::numeric_one,
                                 config, ordered, mapped, order, identity).data());
    assert(!rolloverSleepBucket(*initial.state(), {60, 60}, SplitOrder::numeric_one,
                                 config, ordered, mapped, order, identity).data());
    auto too_many_sources = fresh(0, 60);
    too_many_sources.statistics.current = 60;
    too_many_sources.registered_source_ids = {8, 9};
    auto lower_limit = config; lower_limit.maximum_keys = 1;
    assert(rolloverSleepBucket(too_many_sources, {60, 120}, SplitOrder::numeric_one,
        lower_limit, ordered, mapped, order, identity).status() == BucketRolloverStatus::resource_limit);
    assert(!rolloverSleepBucket(*initial.state(), {60, 120}, static_cast<SplitOrder>(2),
        config, ordered, mapped, order, identity).data());
    config.mask_is_empty = false;
    assert(!rolloverSleepBucket(*initial.state(), {60, 120}, SplitOrder::numeric_one,
                                 config, ordered, mapped, order, identity).data());
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
    std::puts("PASS calendar bucket rollover/fresh reducers/raw-only carry/no old-current clamp/transactional publication");
}
