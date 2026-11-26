#include "SleepSourceLedger.hpp"
#include "SleepSourceSliceAccumulator.hpp"
#include "ModuleReadiness.hpp"
#include "SleepSingleSourceLedgerAdvance.hpp"
#include <cassert>
#include <cstdio>
#include <limits>

using namespace watchfix::healthsupport;

int main() {
    const auto mapped = SourceKeyState::canonicalized_in_one_mapping_session;
    SourceLedger empty;
    auto initial = accumulateSourceLedger(empty, {
        {{2, 0, 20, 8}, 100, true}, {{3, 0, 30, 9}, 200, true},
        {{4, 0, 10, 8}, 100, false}
    }, mapped);
    assert(initial.complete() && initial.data()->ledger.size() == 2);
    assert(initial.data()->contributed_fragments == 3 && initial.data()->native_count_true_arguments == 2);
    assert(initial.data()->ledger.find(100)->decision().category == 2);
    assert(initial.data()->ledger.find(200)->decision().category == 3);
    assert(!initial.data()->ledger.find(999) && empty.size() == 0);

    // TOTAL excludes source9 here, but its independent ledger still exists.
    SleepStageDurationReducer bucket;
    auto total = accumulateOrderedSourceSlice(bucket, {{2, 0, 20, 8}, {3, 0, 30, 9}, {4, 0, 10, 8}},
                                               0, 30, SliceInputState::ordered_valid_split_fragments);
    assert(total.complete() && total.data()->other_source_fragments == 1);
    assert(total.data()->total.decision().category == 2 && initial.data()->ledger.find(200)->decision().category == 3);

    // Opaque canonicalization can group multiple raw sources into one ledger.
    auto grouped = accumulateSourceLedger(empty, {{{5, 0, 10, 1}, -1, true}, {{3, 0, 10, 2}, -1, false}}, mapped);
    assert(grouped.complete() && grouped.data()->ledger.size() == 1);
    assert(grouped.data()->ledger.find(-1)->decision().category == 5);
    auto continuation = accumulateSourceLedger(grouped.data()->ledger, {{{3, 10, 11, 2}, -1, false}}, mapped);
    assert(continuation.complete() && continuation.data()->ledger.find(-1)->decision().category == 3);
    assert(continuation.data()->native_count_true_arguments == 0 && continuation.data()->contributed_fragments == 1);
    assert(grouped.data()->ledger.find(-1)->decision().category == 5); // const transactional original
    auto zero_key = accumulateSourceLedger(empty, {{{3, 0, 1, 1}, 0, false}}, mapped);
    assert(zero_key.complete() && zero_key.data()->ledger.find(0)->decision().category == 3);

    auto no_input = accumulateSourceLedger(initial.data()->ledger, {}, mapped);
    assert(no_input.complete() && no_input.data()->ledger.size() == 2 && no_input.data()->contributed_fragments == 0);
    assert(!accumulateSourceLedger(empty, {}, SourceKeyState::unresolved).data());
    assert(!accumulateSourceLedger(empty, {}, mapped, 0).data());
    auto limit = accumulateSourceLedger(empty, {{{3, 0, 1, 1}, 1, true}, {{4, 0, 1, 2}, 2, true}}, mapped, 1);
    assert(limit.status() == SourceLedgerStatus::key_limit && !limit.data() && empty.size() == 0);
    assert(!accumulateSourceLedger(initial.data()->ledger, {}, mapped, 1).data());
    assert(!accumulateSourceLedger(empty, {{{3, 0, 1, 1}, 1, true}}, mapped, 1, 0).data());
    auto invalid = accumulateSourceLedger(empty, {{{3, 0, 1, 1}, 1, true}, {{6, 0, 1, 2}, 2, true}}, mapped);
    assert(invalid.status() == SourceLedgerStatus::invalid_fragment && !invalid.data());
    assert(!accumulateSourceLedger(empty, {{{3, 1, 1, 1}, 1, true}}, mapped).data());
    const double maximum = std::numeric_limits<double>::max();
    auto maximum_ledger = accumulateSourceLedger(empty, {{{3, 0, maximum, 1}, 1, true}}, mapped);
    assert(maximum_ledger.complete());
    auto overflow = accumulateSourceLedger(maximum_ledger.data()->ledger, {{{3, 0, maximum, 1}, 1, false}}, mapped);
    assert(overflow.status() == SourceLedgerStatus::invalid_accumulation && !overflow.data());
    assert(maximum_ledger.data()->ledger.find(1)->valid());
    PendingStageFragment pending{{5, 0, 60, 8}, false, false, false};
    auto left = advanceSinglePendingWithSourceLedger(bucket, empty, pending, 77, mapped, 0, 30, true);
    assert(left.complete() && left.data()->source_contributed && left.data()->native_source_count_argument);
    assert(left.data()->advance.has_pending && left.data()->ledger.find(77)->decision().category == 5);
    auto right = advanceSinglePendingWithSourceLedger(left.data()->advance.total, left.data()->ledger,
        left.data()->advance.pending, 77, mapped, 30, 60, true);
    assert(right.complete() && !right.data()->advance.has_pending && right.data()->source_contributed);
    assert(!right.data()->native_source_count_argument && !right.data()->advance.native_total_count_argument);
    assert(right.data()->advance.total.decision().category == 5 && right.data()->ledger.find(77)->decision().category == 5);
    assert(empty.size() == 0 && pending.fragment.start == 0 && !pending.per_source_counted);
    auto no_left = advanceSinglePendingWithSourceLedger(bucket, empty, {{3, 0, 1, 8}, false, false, false},
                                                       77, mapped, 0, 0.005, true);
    assert(no_left.complete() && !no_left.data()->source_contributed && no_left.data()->ledger.size() == 0);
    assert(no_left.data()->advance.has_pending && !no_left.data()->advance.pending.per_source_counted);
    auto mask = advanceSinglePendingWithSourceLedger(bucket, empty, pending, 77, mapped, 0, 30, false);
    assert(mask.status() == SingleLedgerStatus::single_transition_rejected && !mask.data());
    assert(mask.single_status() == SingleAdvanceStatus::unsupported_nonempty_mask);
    assert(!advanceSinglePendingWithSourceLedger(bucket, empty, pending, 77, SourceKeyState::unresolved, 0, 30, true).data());
    assert(!advanceSinglePendingWithSourceLedger(bucket, empty, pending, 77, mapped, 0, 30, true, 0).data());
    auto too_many_keys = advanceSinglePendingWithSourceLedger(bucket, initial.data()->ledger, pending,
                                                              300, mapped, 0, 30, true, 2);
    assert(too_many_keys.status() == SingleLedgerStatus::ledger_update_rejected && !too_many_keys.data());
    assert(initial.data()->ledger.size() == 2 && !bucket.decision().has_stage);
    // Source-ledger overflow rejects BOTH total/pending and ledger publication.
    auto ledger_overflow = advanceSinglePendingWithSourceLedger(bucket, maximum_ledger.data()->ledger,
        {{3, 0, maximum, 1}, false, true, false}, 1, mapped, 0, maximum, true);
    assert(ledger_overflow.status() == SingleLedgerStatus::ledger_update_rejected && !ledger_overflow.data());
    assert(!bucket.decision().has_stage && maximum_ledger.data()->ledger.find(1)->valid());
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
    std::puts("PASS source ledger independent reducers/canonical opaque keys/no native counters/no device");
}
