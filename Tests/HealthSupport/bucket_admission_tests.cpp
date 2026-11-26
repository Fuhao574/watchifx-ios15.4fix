#include "SleepBucketAdmission.hpp"
#include "SleepStatisticsBucketOutput.hpp"
#include "SleepSourceIdentityMap.hpp"
#include "ModuleReadiness.hpp"
#include <cassert>
#include <cstdio>
#include <stdexcept>

using namespace watchfix::healthsupport;
static BucketLifecycleState fresh(double start, double end) {
    BucketLifecycleState value{{start, end}, {}, {}, {}};
    value.statistics.current = start;
    value.statistics.interval_end = end;
    return value;
}
int main() {
    const auto ordered = PendingOrderState::native_equivalent_source_then_start_order;
    const auto mapped = SourceKeyState::canonicalized_in_one_mapping_session;
    BucketAdvanceConfiguration config; config.mask_is_empty = true;
    BucketLifecycleState first = fresh(0, 60);
    std::size_t lookup_calls = 0;
    AdmissionIdentity identity = [&](std::int64_t source) {
        ++lookup_calls;
        AdmissionSourceIdentity resolved; resolved.resolved = true;
        resolved.ledger_key = source; resolved.has_bundle_group = true; resolved.bundle_group = source;
        return resolved;
    };
    RegisteredPendingOrdering fixture_order = [](const std::vector<MappedPendingStage> &pending,
                                                 const std::vector<std::int64_t> &sources) {
        assert(!sources.empty());
        std::vector<std::size_t> indices;
        for (std::size_t i = 0; i < pending.size(); ++i) indices.push_back(i);
        return indices; // explicit small fixture order, NOT native general sort
    };
    auto admitted = admitRawStageToBucket(first, {3, 0, 120, 8}, true, SplitOrder::numeric_one,
                                          config, ordered, mapped, fixture_order, identity);
    assert(admitted.complete() && lookup_calls == 1);
    assert(admitted.state()->statistics.pending.size() == 1 && admitted.state()->raw_carry.size() == 1);
    assert(admitted.state()->raw_carry[0].start == 60 && admitted.state()->raw_carry[0].end == 120);
    assert(admitted.state()->registered_source_ids.size() == 1 && admitted.state()->registered_source_ids[0] == 8);
    assert(admitted.state()->statistics.ledger.size() == 1);
    assert(!admitted.state()->statistics.ledger.find(8)->decision().has_stage); // no zero-time fake add
    assert(first.statistics.pending.empty() && first.statistics.ledger.size() == 0 && first.raw_carry.empty());

    // The carry is captured at admission, independent of old pending/current.
    const StageFragment carry = admitted.state()->raw_carry[0];
    auto finished = advanceSleepBucket(admitted.state()->statistics, 60, config, ordered, mapped, {});
    assert(finished.complete() && finished.data()->state.pending.empty());
    auto first_output = finalizeSleepStatisticsBucket(finished.data()->state.total, {0, 60}, true);
    assert(first_output.succeeded() && first_output.interval()->category == 3);
    // New bucket's reducers/mapping must be fresh, never copied from finished.
    BucketLifecycleState second = fresh(60, 120);
    auto replayed = admitRawStageToBucket(second, carry, true, SplitOrder::numeric_one,
                                          config, ordered, mapped, fixture_order, identity);
    assert(replayed.complete() && lookup_calls == 2);
    const auto &pending = replayed.state()->statistics.pending.front().pending;
    assert(!pending.history_flag && !pending.per_source_counted && !pending.total_counted);
    assert(!replayed.state()->statistics.total.decision().has_stage);
    assert(!replayed.state()->statistics.ledger.find(8)->decision().has_stage);
    auto second_finished = advanceSleepBucket(replayed.state()->statistics, 120, config, ordered, mapped, {});
    assert(second_finished.complete());
    auto second_output = finalizeSleepStatisticsBucket(second_finished.data()->state.total, {60, 120}, true);
    assert(second_output.succeeded() && second_output.interval()->category == 3);
    auto legacy = projectLegacySleepSummary({*first_output.interval(), *second_output.interval()},
                                             StatisticsInputState::resolved_statistics_intervals);
    assert(legacy.complete() && legacy.data()->asleep_duration == 120);
    assert(legacy.data()->asleep_segments.size() == 1);

    // New source must be registered BEFORE old pending is sorted/advanced. New
    // sample is still absent from pending at that call, and appended afterward.
    BucketLifecycleState prior = fresh(0, 120);
    prior.statistics.pending = {
        {{{3, 0, 90, 8}, false, false, false}, true, 8, true, 8},
        {{{4, 10, 100, 9}, false, false, false}, true, 9, true, 9}
    };
    prior.registered_source_ids = {8, 9};
    bool observed_registration = false;
    RegisteredPendingOrdering inspected_order = [&](const std::vector<MappedPendingStage> &items,
                                                    const std::vector<std::int64_t> &sources) {
        assert(items.size() == 2 && sources.size() == 3 && sources.back() == 10);
        for (const auto &item : items) assert(item.pending.fragment.source_id != 10);
        observed_registration = true; return std::vector<std::size_t>{0, 1};
    };
    auto appended = admitRawStageToBucket(prior, {5, 45, 110, 10}, true, SplitOrder::numeric_one,
                                          config, ordered, mapped, inspected_order, identity);
    assert(appended.complete() && observed_registration && appended.state()->statistics.current == 30);
    assert(appended.state()->statistics.pending.size() == 3);
    assert(appended.state()->statistics.pending.back().pending.fragment.start == 45);

    const std::size_t before_lookup = lookup_calls;
    auto only_future = admitRawStageToBucket(first, {3, 70, 80, 8}, true, SplitOrder::numeric_one,
                                             config, ordered, mapped, fixture_order, identity);
    assert(only_future.complete() && only_future.state()->statistics.pending.empty());
    assert(only_future.state()->raw_carry.size() == 1 && lookup_calls == before_lookup);
    auto unresolved = admitRawStageToBucket(first, {3, 0, 10, 8}, true, SplitOrder::numeric_one,
                                            config, ordered, mapped, fixture_order, {});
    assert(unresolved.status() == BucketAdmissionStatus::identity_unresolved && !unresolved.state());
    auto throwing = admitRawStageToBucket(first, {3, 0, 10, 8}, true, SplitOrder::numeric_one,
        config, ordered, mapped, fixture_order, [](std::int64_t) -> AdmissionSourceIdentity { throw std::runtime_error("fixture"); });
    assert(throwing.status() == BucketAdmissionStatus::adapter_failed && !throwing.state());
    assert(first.statistics.pending.empty() && first.raw_carry.empty());
    auto near_start = admitRawStageToBucket(first, {3, -0.005, -0.001, 8}, true, SplitOrder::numeric_one,
                                            config, ordered, mapped, fixture_order, identity);
    assert(near_start.complete() && near_start.state()->statistics.pending.front().pending.fragment.start == -0.005);
    assert(near_start.state()->statistics.current == 0); // rounded target behind current causes no work
    // Entry checks must hold on carry-only, entirely-before and no-advance
    // paths too; they cannot depend on whether advance happens to be called.
    const std::vector<StageFragment> branch_inputs{{3, 70, 80, 8}, {3, -30, -10, 8}, {3, 0, 10, 8}};
    for (const auto &input : branch_inputs) {
        auto invalid_config = config; invalid_config.merge_granularity = std::numeric_limits<double>::quiet_NaN();
        assert(admitRawStageToBucket(first, input, false, SplitOrder::numeric_one, invalid_config,
            ordered, mapped, fixture_order, identity).status() == BucketAdmissionStatus::invalid_configuration);
        auto unknown_mask = config; unknown_mask.mask_is_empty = false;
        assert(admitRawStageToBucket(first, input, false, SplitOrder::numeric_one, unknown_mask,
            ordered, mapped, fixture_order, identity).status() == BucketAdmissionStatus::unsupported_mask);
        assert(admitRawStageToBucket(first, input, false, SplitOrder::numeric_one, config,
            PendingOrderState::unresolved, mapped, fixture_order, identity).status() == BucketAdmissionStatus::unresolved_order_or_mapping);
        assert(admitRawStageToBucket(first, input, false, SplitOrder::numeric_one, config,
            ordered, SourceKeyState::unresolved, fixture_order, identity).status() == BucketAdmissionStatus::unresolved_order_or_mapping);
        auto invalid_original = first;
        invalid_original.statistics.pending.push_back({{{99, 0, 1, 8}, false, false, false}, true, 8, true, 8});
        assert(admitRawStageToBucket(invalid_original, input, false, SplitOrder::numeric_one, config,
            ordered, mapped, fixture_order, identity).status() == BucketAdmissionStatus::invalid_state);
        auto over_limit = first;
        auto map = accumulateSourceLedger(over_limit.statistics.ledger,
            {{{3, 0, 1, 8}, 8, false}, {{4, 0, 1, 9}, 9, false}}, mapped);
        assert(map.complete()); over_limit.statistics.ledger = map.data()->ledger;
        auto lower_limit = config; lower_limit.maximum_keys = 1;
        assert(admitRawStageToBucket(over_limit, input, false, SplitOrder::numeric_one, lower_limit,
            ordered, mapped, fixture_order, identity).status() == BucketAdmissionStatus::resource_limit);
    }
    // Callback effects are NOT rolled back: this disposable test context sees
    // lookup before ensuring a new key fails, while owned bucket remains intact.
    auto one_key_state = first;
    auto existing_key = ensureSourceLedgerKey(one_key_state.statistics.ledger, 1, mapped);
    assert(existing_key.complete()); one_key_state.statistics.ledger = existing_key.data()->ledger;
    auto one_key_config = config; one_key_config.maximum_keys = 1;
    const std::size_t before_failure_lookup = lookup_calls;
    auto after_callback_failure = admitRawStageToBucket(one_key_state, {3, 0, 10, 8}, false,
        SplitOrder::numeric_one, one_key_config, ordered, mapped, fixture_order, identity);
    assert(after_callback_failure.status() == BucketAdmissionStatus::ledger_failed && !after_callback_failure.state());
    assert(lookup_calls == before_failure_lookup + 1 && one_key_state.statistics.ledger.size() == 1);
    assert(one_key_state.statistics.pending.empty());
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
    std::puts("PASS raw admission execution/source-before-advance/raw carry/fresh bucket replay/legacy projection");
}
