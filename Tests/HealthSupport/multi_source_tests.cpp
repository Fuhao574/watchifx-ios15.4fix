#include "SleepMultiSourceAdvance.hpp"
#include "SleepSingleSourceLedgerAdvance.hpp"
#include "ModuleReadiness.hpp"
#include <cassert>
#include <cstdio>

using namespace watchfix::healthsupport;
static MappedPendingStage item(std::int64_t category, double start, double end, std::int64_t source,
                              std::int64_t key, bool has_bundle = true) {
    return {{{category, start, end, source}, false, false, false}, true, key, has_bundle, key};
}
int main() {
    const auto ordered = PendingOrderState::native_equivalent_source_then_start_order;
    const auto mapped = SourceKeyState::canonicalized_in_one_mapping_session;
    SleepStageDurationReducer total; SourceLedger ledger;
    const std::vector<MappedPendingStage> inputs = {item(3, 0, 9, 8, 10), item(2, 1, 8, 9, 20)};
    auto result = advanceOrderedMultiPending(total, ledger, inputs, ordered, mapped, 2, 5, true, true);
    assert(result.complete() && result.data()->current == 5 && result.data()->pending.size() == 2);
    assert(result.data()->total_source_id == 8 && result.data()->total_contributions == 1);
    assert(result.data()->source_contributions == 2 && result.data()->ledger.size() == 2);
    assert(result.data()->total.decision().category == 3 && result.data()->ledger.find(20)->decision().category == 2);
    const auto &a = result.data()->pending[0].pending, &b = result.data()->pending[1].pending;
    assert(a.fragment.start == 5 && a.fragment.end == 9 && a.total_counted && a.per_source_counted && !a.history_flag);
    assert(b.fragment.start == 5 && b.fragment.end == 8 && !b.total_counted && b.per_source_counted && !b.history_flag);
    assert(inputs[0].pending.fragment.start == 0 && !inputs[0].pending.total_counted && ledger.size() == 0);
    // Same canonical group: only first raw source represents that group within
    // this advance. The ledger accumulator itself must not choose this for us.
    auto grouped = advanceOrderedMultiPending(total, ledger,
        {item(3, 0, 9, 8, 10), item(5, 1, 8, 9, 10)}, ordered, mapped, 2, 5, true, true);
    assert(grouped.complete() && grouped.data()->source_contributions == 1);
    assert(grouped.data()->ledger.size() == 1 && grouped.data()->pending[1].pending.per_source_counted == false);
    // Future item left-invalid stays whole and does not establish a source.
    auto future = advanceOrderedMultiPending(total, ledger,
        {item(4, 10, 20, 8, 10), item(2, 1, 8, 9, 20)}, ordered, mapped, 0, 5, true, true);
    assert(future.complete() && future.data()->total_source_id == 9);
    assert(future.data()->pending[0].pending.fragment.start == 10);
    assert(!future.data()->pending[0].pending.total_counted && !future.data()->pending[0].pending.per_source_counted);
    // Boundary beyond end preserves whole valid left, removes pending, never
    // constructs an interval ending beyond the original fragment.
    auto done = advanceOrderedMultiPending(total, ledger,
        {item(4, 0, 1, 8, 10), item(5, 0.5, 2, 8, 10)}, ordered, mapped, 0, 5, true, true);
    assert(done.complete() && done.data()->pending.empty() && done.data()->current == 5);
    assert(done.data()->total.decision().category == 5);
    // Multi->single permitted only after caller establishes next dispatch. This
    // fixture supplies known order; native same-start sort is still not modeled.
    auto one = advanceOrderedMultiPending(total, ledger,
        {item(3, 0, 2, 8, 10), item(4, 0.5, 9, 9, 20)}, ordered, mapped, 0, 5, true, true);
    assert(one.complete() && one.data()->pending.size() == 1);
    auto single = advanceSinglePendingWithSourceLedger(one.data()->total, one.data()->ledger,
        one.data()->pending[0].pending, 20, mapped, 5, 9, true);
    assert(single.complete() && !single.data()->advance.has_pending);
    assert(single.data()->advance.total.decision().category == 4);
    assert(single.data()->ledger.find(20)->decision().category == 4);
    auto nil_bundle = advanceOrderedMultiPending(total, ledger,
        {item(3, 0, 9, 8, 0, false), item(5, 1, 8, 9, 0, false)}, ordered, mapped, 0, 5, true, true);
    assert(nil_bundle.complete() && nil_bundle.data()->ledger.size() == 0 && nil_bundle.data()->source_contributions == 0);
    auto missing_a = item(3, 0, 9, 8, 10);
    auto missing_b = item(5, 1, 8, 9, 20);
    missing_a.has_ledger_key = false; missing_b.has_ledger_key = false;
    auto missing_key = advanceOrderedMultiPending(total, ledger, {missing_a, missing_b}, ordered, mapped, 0, 5, true, true);
    assert(missing_key.complete() && missing_key.data()->source_contributions == 0 && missing_key.data()->ledger.size() == 0);
    auto group_a = item(3, 0, 9, 8, 10), group_b = item(5, 1, 8, 9, 20);
    group_a.bundle_group = 700; group_b.bundle_group = 700;
    auto distinct_key_same_group = advanceOrderedMultiPending(total, ledger, {group_a, group_b}, ordered, mapped, 0, 5, true, true);
    assert(distinct_key_same_group.complete() && distinct_key_same_group.data()->source_contributions == 1);
    assert(distinct_key_same_group.data()->ledger.find(10) && !distinct_key_same_group.data()->ledger.find(20));
    group_a = item(3, 0, 9, 8, 10); group_b = item(5, 1, 8, 9, 20);
    group_a.pending.total_counted = group_a.pending.per_source_counted = true;
    group_b.pending.total_counted = group_b.pending.per_source_counted = true;
    auto already_counted = advanceOrderedMultiPending(total, ledger, {group_a, group_b}, ordered, mapped, 0, 5, true, true);
    assert(already_counted.complete() && already_counted.data()->total_contributions == 1 && already_counted.data()->source_contributions == 2);
    assert(already_counted.data()->total.decision().category == 3 && already_counted.data()->ledger.find(20)->decision().category == 5);
    // Nil bundle still has a single-path ledger key, but multi must not update
    // it; switching to single later must not lose that key or misread it as NONE.
    auto nil_to_single = advanceOrderedMultiPending(total, ledger,
        {item(3, 0, 2, 8, 10, false), item(4, 0.5, 9, 9, 10, false)}, ordered, mapped, 0, 5, true, true);
    assert(nil_to_single.complete() && nil_to_single.data()->source_contributions == 0);
    assert(nil_to_single.data()->pending.size() == 1 && nil_to_single.data()->pending[0].has_ledger_key);
    auto nil_single = advanceSinglePendingWithSourceLedger(nil_to_single.data()->total, nil_to_single.data()->ledger,
        nil_to_single.data()->pending[0].pending, 10, mapped, 5, 9, true);
    assert(nil_single.complete() && nil_single.data()->ledger.find(10)->decision().category == 4);
    auto no_source_ledger = advanceOrderedMultiPending(total, ledger, inputs, ordered, mapped, 0, 5, true, false);
    assert(no_source_ledger.complete() && no_source_ledger.data()->ledger.size() == 0);
    assert(!no_source_ledger.data()->pending[0].pending.per_source_counted);
    assert(!advanceOrderedMultiPending(total, ledger, inputs, PendingOrderState::unresolved, mapped, 0, 5, true, true).data());
    assert(!advanceOrderedMultiPending(total, ledger, inputs, ordered, mapped, 0, 5, false, true).data());
    assert(!advanceOrderedMultiPending(total, ledger, inputs, ordered, mapped, 0, 5, true, true, 1).data());
    auto key_limit = advanceOrderedMultiPending(total, ledger, inputs, ordered, mapped, 0, 5, true, true, 10, 1);
    assert(key_limit.status() == MultiAdvanceStatus::ledger_failed && !key_limit.data());
    auto invalid = advanceOrderedMultiPending(total, ledger,
        {item(3, 0, 9, 8, 10), item(99, 1, 8, 9, 20)}, ordered, mapped, 0, 5, true, true);
    assert(invalid.status() == MultiAdvanceStatus::invalid_fragment && !invalid.data());
    auto event = chooseMultiPendingAdvance({item(3, 0, 100, 8, 10), item(4, 45, 90, 9, 20)}, 31, 80, 30);
    assert(event.complete() && event.data()->next == 60); // first event45, not target80
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
    std::puts("PASS ordered multi advance/independent total-source gates/flags/residuals/no native sorting");
}
