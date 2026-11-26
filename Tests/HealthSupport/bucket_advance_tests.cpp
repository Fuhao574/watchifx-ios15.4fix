#include "SleepBucketAdvance.hpp"
#include <string>
#include "SleepStatisticsBucketOutput.hpp"
#include "ModuleReadiness.hpp"
#include <cassert>
#include <cstdio>
#include <stdexcept>

using namespace watchfix::healthsupport;
static MappedPendingStage sample(std::int64_t category, double start, double end, std::int64_t source, std::int64_t key) {
    return {{{category, start, end, source}, false, false, false}, true, key, true, key};
}
int main() {
    const auto ordered = PendingOrderState::native_equivalent_source_then_start_order;
    const auto mapped = SourceKeyState::canonicalized_in_one_mapping_session;
    BucketAdvanceConfiguration configuration; configuration.mask_is_empty = true;
    SleepBucketState state; state.current = 0; state.interval_end = 120;
    state.pending = {sample(3, 0, 45, 8, 10), sample(4, 15, 90, 9, 20)};
    std::size_t order_calls = 0;
    // Fixture-only supplied permutations. Equal starts are deliberately not
    // resolved by an invented provider priority in the module.
    PendingOrdering fixture_order = [&](const std::vector<MappedPendingStage> &pending) {
        ++order_calls;
        assert(pending.size() == 2);
        return std::vector<std::size_t>{0, 1};
    };
    auto result = advanceSleepBucket(state, 120, configuration, ordered, mapped, fixture_order);
    assert(result.complete() && result.data()->effective_target == 120 && result.data()->state.current == 120);
    assert(result.data()->multi_steps == 2 && result.data()->single_steps == 1 && result.data()->empty_steps == 0);
    assert(result.data()->state.pending.empty() && order_calls == 2);
    assert(result.data()->state.total.decision().category == 3); // equal45, first category3 wins
    assert(result.data()->state.ledger.size() == 2);
    assert(result.data()->state.ledger.find(10)->decision().category == 3);
    assert(result.data()->state.ledger.find(20)->decision().category == 4);
    assert(state.current == 0 && state.pending[0].pending.fragment.start == 0 && !state.pending[0].pending.total_counted);
    assert(!state.total.decision().has_stage && state.ledger.size() == 0);
    auto bucket = finalizeSleepStatisticsBucket(result.data()->state.total, {0, 120}, true);
    assert(bucket.succeeded() && bucket.interval());
    auto legacy = projectLegacySleepSummary({*bucket.interval()}, StatisticsInputState::resolved_statistics_intervals);
    assert(legacy.complete() && legacy.data()->asleep_duration == 120);

    SleepBucketState empty; empty.interval_end = 120;
    auto empty_result = advanceSleepBucket(empty, 120, configuration, ordered, mapped, {});
    assert(empty_result.complete() && empty_result.data()->empty_steps == 1 && empty_result.data()->state.current == 120);
    auto no_op = advanceSleepBucket(state, 15, configuration, ordered, mapped, {}); // floor target0
    assert(no_op.complete() && no_op.data()->steps == 0 && no_op.data()->state.current == 0);
    SleepBucketState tiny; tiny.interval_end = 1; tiny.pending = {sample(5, 0, 1, 8, 10)};
    configuration.merge_granularity = 0.001;
    auto short_left = advanceSleepBucket(tiny, 0.005, configuration, ordered, mapped, {});
    assert(short_left.complete() && short_left.data()->state.current == 0.005);
    assert(short_left.data()->state.pending.size() == 1 && short_left.data()->state.pending[0].pending.fragment.start == 0);
    assert(short_left.data()->state.ledger.size() == 0 && !short_left.data()->state.total.decision().has_stage);

    configuration.merge_granularity = 30;
    auto bad_sort = advanceSleepBucket(state, 120, configuration, ordered, mapped,
        [](const std::vector<MappedPendingStage> &) { return std::vector<std::size_t>{0, 0}; });
    assert(bad_sort.status() == BucketAdvanceStatus::ordering_rejected && !bad_sort.data());
    auto missing_sort = advanceSleepBucket(state, 120, configuration, ordered, mapped, {});
    assert(missing_sort.status() == BucketAdvanceStatus::ordering_rejected && !missing_sort.data());
    auto throwing_sort = advanceSleepBucket(state, 120, configuration, ordered, mapped,
        [](const std::vector<MappedPendingStage> &) -> std::vector<std::size_t> { throw std::runtime_error("fixture"); });
    assert(throwing_sort.status() == BucketAdvanceStatus::ordering_callback_failed && !throwing_sort.data());
    configuration.maximum_steps = 1;
    auto limit = advanceSleepBucket(state, 120, configuration, ordered, mapped, fixture_order);
    assert(limit.status() == BucketAdvanceStatus::iteration_limit && !limit.data());
    assert(state.current == 0 && state.ledger.size() == 0);
    configuration.maximum_steps = 100;
    configuration.maximum_keys = 1;
    auto ledger_limit = advanceSleepBucket(state, 120, configuration, ordered, mapped, fixture_order);
    assert(ledger_limit.status() == BucketAdvanceStatus::transition_failed && !ledger_limit.data());
    configuration.maximum_keys = 100;
    configuration.mask_is_empty = false;
    assert(advanceSleepBucket(state, 120, configuration, ordered, mapped, fixture_order).status() == BucketAdvanceStatus::unsupported_mask);
    configuration.mask_is_empty = true;
    configuration.separate_by_source = false;
    auto total_only = advanceSleepBucket(state, 120, configuration, ordered, mapped, fixture_order);
    assert(total_only.complete() && total_only.data()->state.ledger.size() == 0 && total_only.data()->state.pending.empty());
    assert(total_only.data()->state.total.decision().category == 3);
    configuration.separate_by_source = true;
    SleepBucketState overrun;
    overrun.current = 31; overrun.interval_end = 45;
    overrun.pending = {sample(3, 0, 100, 8, 10), sample(4, 45, 90, 9, 20)};
    auto over_target = advanceSleepBucket(overrun, 45, configuration, ordered, mapped, fixture_order);
    assert(over_target.complete() && over_target.data()->effective_target == 45 && over_target.data()->state.current == 60);
    assert(over_target.data()->state.current > over_target.data()->state.interval_end);
    assert(!advanceSleepBucket(state, 120, configuration, PendingOrderState::unresolved, mapped, fixture_order).data());
    assert(!advanceSleepBucket(state, 120, configuration, ordered, SourceKeyState::unresolved, fixture_order).data());
    SleepBucketState invalid = state; invalid.pending.back().pending.fragment.category = 6;
    assert(!advanceSleepBucket(invalid, 120, configuration, ordered, mapped, fixture_order).data());
    std::vector<std::string> lookups;
    SourceConsumption live;
    live.bundle = [&](std::int64_t source) {
        lookups.push_back("bundle" + std::to_string(source));
        ConsumptionBundle value; value.resolved = true; value.nonnull = true; value.group = 1; return value;
    };
    live.key = [&](std::int64_t source) {
        lookups.push_back("key" + std::to_string(source));
        ConsumptionKey value; value.resolved = true; value.key = source == 8 ? 101 : 202; return value;
    };
    auto consumed = advanceSleepBucket(state, 120, configuration, ordered, mapped, fixture_order, &live);
    assert(consumed.complete());
    // Multi checks bundle for both valid lefts, key only for representative;
    // single uses key directly. Stale admission key10/20 must never be reused.
    const std::vector<std::string> expected{"bundle8","key8","bundle9","bundle8","key8","bundle9","key9"};
    assert(lookups == expected);
    assert(!consumed.data()->state.ledger.find(10) && !consumed.data()->state.ledger.find(20));
    assert(consumed.data()->state.ledger.find(101) && consumed.data()->state.ledger.find(202));
    lookups.clear();
    live.bundle = [&](std::int64_t source) {
        lookups.push_back("nil" + std::to_string(source));
        ConsumptionBundle value; value.resolved = true; return value;
    };
    consumed = advanceSleepBucket(state, 120, configuration, ordered, mapped, fixture_order, &live);
    assert(consumed.complete() && consumed.data()->state.ledger.size() == 1 && consumed.data()->state.ledger.find(202));
    assert((lookups == std::vector<std::string>{"nil8","nil9","nil8","nil9","key9"}));
    live.key = [](std::int64_t) -> ConsumptionKey { throw std::runtime_error("fixture"); };
    consumed = advanceSleepBucket(state, 120, configuration, ordered, mapped, fixture_order, &live);
    assert(!consumed.complete() && !consumed.data() && state.ledger.size() == 0);
    SourceConsumption nil_only;
    std::size_t nil_calls = 0;
    nil_only.bundle = [&](std::int64_t) { ++nil_calls; ConsumptionBundle value; value.resolved = true; return value; };
    auto nil_multi = advanceOrderedMultiPending(state.total, state.ledger, state.pending, ordered, mapped,
                                                0, 30, true, true, 100, 100, &nil_only);
    assert(nil_multi.complete() && nil_calls == 2 && nil_multi.data()->ledger.size() == 0);
    nil_only.bundle = [](std::int64_t) { ConsumptionBundle value; value.resolved = true; value.nonnull = true; return value; };
    assert(!advanceOrderedMultiPending(state.total, state.ledger, state.pending, ordered, mapped,
                                       0, 30, true, true, 100, 100, &nil_only).complete());
    SourceConsumption never;
    never.bundle = [](std::int64_t) -> ConsumptionBundle { throw std::runtime_error("must-not-call"); };
    never.key = [](std::int64_t) -> ConsumptionKey { throw std::runtime_error("must-not-call"); };
    const std::vector<MappedPendingStage> future{sample(3, 60, 90, 8, 10),sample(4, 70, 100, 9, 20)};
    auto no_left = advanceOrderedMultiPending(state.total, state.ledger, future, ordered, mapped,
                                              0, 30, true, true, 100, 100, &never);
    assert(no_left.complete() && no_left.data()->pending.size() == 2);
    assert(advanceOrderedMultiPending(state.total, state.ledger, state.pending, ordered, mapped,
                                     0, 30, true, false, 100, 100, &never).complete());
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
    std::puts("PASS bounded bucket orchestration/multi-single-empty/transactional failure/ordering dependency explicit");
}
