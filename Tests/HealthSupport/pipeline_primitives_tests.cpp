// Synthetic inputs only; native single-sample fast path/source order not modeled.
#include "SleepStageFragments.hpp"
#include "SleepSourceMergeAdvance.hpp"
#include "SleepSourceSliceAccumulator.hpp"
#include "SleepAdvanceDispatch.hpp"
#include "SleepStatisticsBucketOutput.hpp"
#include "SleepStageDurationReducer.hpp"
#include "ModuleReadiness.hpp"
#include "LegacyDerivedSummary.hpp"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <limits>

using namespace watchfix::healthsupport;

static void testSplits() {
    for (std::int64_t category = 1; category <= 5; ++category) {
        const StageFragment original{category, 0, 60, -42};
        auto split = splitStageFragment(original, 30, SplitOrder::numeric_one);
        assert(split.complete() && split.data()->left_valid && split.data()->right_valid);
        assert(split.data()->left.start == 0 && split.data()->left.end == 30);
        assert(split.data()->right.start == 30 && split.data()->right.end == 60);
        assert(split.data()->left.category == category && split.data()->right.category == category);
        assert(split.data()->left.source_id == -42 && split.data()->right.source_id == -42);
        assert(original.start == 0 && original.end == 60 && original.category == category);
        auto start = splitStageFragment(original, 0, SplitOrder::numeric_zero);
        auto end = splitStageFragment(original, 60, SplitOrder::numeric_one);
        assert(start.complete() && !start.data()->left_valid && start.data()->right_valid);
        assert(end.complete() && end.data()->left_valid && !end.data()->right_valid);
    }
    // Both sides shorter than0.01: mode determines which full fragment survives.
    const StageFragment short_fragment{4, 0, 0.015, 7};
    auto zero = splitStageFragment(short_fragment, 0.0075, SplitOrder::numeric_zero);
    auto one = splitStageFragment(short_fragment, 0.0075, SplitOrder::numeric_one);
    assert(zero.complete() && one.complete());
    assert(zero.data()->left_valid && !zero.data()->right_valid);
    assert(!one.data()->left_valid && one.data()->right_valid);
    assert(zero.data()->left.end == short_fragment.end && one.data()->right.start == short_fragment.start);
    // Exact0.01 belongs to split, not the strict short-side branch.
    auto threshold = splitStageFragment({3, 0, 0.02, 8}, 0.01, SplitOrder::numeric_one);
    assert(threshold.complete() && threshold.data()->left_valid && threshold.data()->right_valid);
    auto near_start = splitStageFragment({5, 0, 1, 2}, 0.005, SplitOrder::numeric_one);
    auto near_end = splitStageFragment({5, 0, 1, 2}, 0.995, SplitOrder::numeric_zero);
    assert(near_start.complete() && near_end.complete());
    assert(!near_start.data()->left_valid && near_start.data()->right.start == 0);
    assert(!near_end.data()->right_valid && near_end.data()->left.end == 1);
    for (std::int64_t category : {-1, 0, 6}) {
        auto invalid = splitStageFragment({category, 0, 1, 1}, 0.5, SplitOrder::numeric_zero);
        assert(!invalid.complete() && !invalid.data());
    }
    assert(!splitStageFragment({3, 0, 0, 1}, 0, SplitOrder::numeric_zero).data());
    assert(!splitStageFragment({3, 2, 1, 1}, 1, SplitOrder::numeric_zero).data());
    assert(!splitStageFragment({3, 0, 1, 1}, -1, SplitOrder::numeric_zero).data());
    assert(!splitStageFragment({3, 0, 1, 1}, 2, SplitOrder::numeric_zero).data());
    assert(!splitStageFragment({3, 0, 1, 1}, 0.5, static_cast<SplitOrder>(2)).data());
    assert(!splitStageFragment({3, 0, 1, 1}, std::numeric_limits<double>::quiet_NaN(), SplitOrder::numeric_zero).data());
    const double maximum = std::numeric_limits<double>::max();
    assert(!splitStageFragment({3, -maximum, maximum, 1}, 0, SplitOrder::numeric_one).data());
    // Preserve audited cancellation behavior: (whole-left) can be0 even when
    // (end-time) is1. A valid left-side result may retain the WHOLE original.
    const double large = 18014398509481984.0; //2^54, exactly representable
    for (SplitOrder mode : {SplitOrder::numeric_zero, SplitOrder::numeric_one}) {
        auto cancelled = splitStageFragment({3, -large, 1, 7}, 0, mode);
        assert(cancelled.complete() && cancelled.data()->left_valid && !cancelled.data()->right_valid);
        assert(cancelled.data()->left.start == -large && cancelled.data()->left.end == 1);
        assert(cancelled.data()->left.category == 3 && cancelled.data()->left.source_id == 7);
    }
    for (double length : {0.005, std::numeric_limits<double>::denorm_min()}) {
        for (double time : {0.0, length}) {
            auto short_zero = splitStageFragment({3, 0, length, 9}, time, SplitOrder::numeric_zero);
            auto short_one = splitStageFragment({3, 0, length, 9}, time, SplitOrder::numeric_one);
            assert(short_zero.complete() && short_one.complete());
            assert(short_zero.data()->left_valid && !short_zero.data()->right_valid);
            assert(!short_one.data()->left_valid && short_one.data()->right_valid);
            assert(short_zero.data()->left.start == 0 && short_zero.data()->left.end == length);
            assert(short_one.data()->right.start == 0 && short_one.data()->right.end == length);
            SleepStageDurationReducer reducer;
            assert(reducer.add(short_zero.data()->left.category, 0, length));
            assert(reducer.valid());
            assert(reducer.decision().has_stage == (length > std::numeric_limits<double>::min()));
        }
    }
    const double before_threshold = std::nextafter(0.01, 0.0);
    const double after_threshold = std::nextafter(0.01, 1.0);
    auto below = splitStageFragment({3, 0, 1, 1}, before_threshold, SplitOrder::numeric_one);
    auto above = splitStageFragment({3, 0, 1, 1}, after_threshold, SplitOrder::numeric_one);
    assert(below.complete() && above.complete());
    assert(!below.data()->left_valid && above.data()->left_valid && above.data()->right_valid);
}

static void testAdvance() {
    struct Case { double current, event, g, expected; };
    const Case cases[] = {
        {0, 10, 30, 30}, {0, 30, 30, 30}, {0, 100, 30, 90},
        {31, 35, 30, 60}, {31, 45, 30, 60}, {31, 90, 30, 90},
        {-31, -20, 30, -30}, {-30, -20, 30, 0}, {-1, 1, 30, 0},
        {0, 60, 60, 60}, {0, 1, 0.5, 1}
    };
    for (const auto &test : cases) {
        auto result = nextMultiSampleSourceMergeTime(test.current, test.event, test.g);
        assert(result.complete() && result.data()->next == test.expected);
        assert(result.data()->next > test.current);
    }
    // Demonstrates no invented event/target clamp: next can pass the event or
    // stop before it, exactly as the audited multi-sample rounding does.
    auto exceeds_event = nextMultiSampleSourceMergeTime(0, 10, 30);
    auto precedes_event = nextMultiSampleSourceMergeTime(0, 100, 30);
    assert(exceeds_event.complete() && precedes_event.complete());
    assert(exceeds_event.data()->next > 10);
    assert(precedes_event.data()->next < 100);
    for (double g : {0.0, -1.0, std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()})
        assert(!nextMultiSampleSourceMergeTime(0, 10, g).data());
    assert(!nextMultiSampleSourceMergeTime(10, 10, 30).data());
    assert(!nextMultiSampleSourceMergeTime(20, 10, 30).data());
    const double maximum = std::numeric_limits<double>::max();
    assert(!nextMultiSampleSourceMergeTime(maximum / 2, maximum, maximum).data());
    const double current = 30.0;
    const double event = std::nextafter(current, std::numeric_limits<double>::infinity());
    auto no_progress = nextMultiSampleSourceMergeTime(current, event, (event - current) / 10.0);
    assert(no_progress.status() == SourceAdvanceStatus::no_representable_progress && !no_progress.data());
    auto nonfinite_gap = nextMultiSampleSourceMergeTime(-maximum, maximum, maximum / 2);
    assert(nonfinite_gap.status() == SourceAdvanceStatus::nonfinite_advance_duration && !nonfinite_gap.data());
    auto division_overflow = nextMultiSampleSourceMergeTime(0, 1, std::numeric_limits<double>::denorm_min());
    assert(division_overflow.status() == SourceAdvanceStatus::nonfinite_arithmetic && !division_overflow.data());
    const double power1023 = std::ldexp(1.0, 1023);
    auto multiplication_overflow = nextMultiSampleSourceMergeTime(-maximum, -1.5 * power1023, power1023);
    assert(multiplication_overflow.status() == SourceAdvanceStatus::nonfinite_arithmetic && !multiplication_overflow.data());
    auto decimal_grid = nextMultiSampleSourceMergeTime(0, 0.3, 0.1);
    assert(decimal_grid.complete());
    const double binary_grid = std::max(0.1 * std::floor(0.3 / 0.1), 0.1 * std::floor((0.0 + 0.1) / 0.1));
    assert(decimal_grid.data()->next == binary_grid);
}

static void testSplitFeedsReducerWithoutCategoryScaling() {
    const StageFragment fragment{5, 0, 60, 8};
    auto split = splitStageFragment(fragment, 30, SplitOrder::numeric_zero);
    assert(split.complete());
    SleepStageDurationReducer before, after;
    assert(before.add(fragment.category, fragment.start, fragment.end));
    assert(after.add(split.data()->left.category, split.data()->left.start, split.data()->left.end));
    assert(after.add(split.data()->right.category, split.data()->right.start, split.data()->right.end));
    assert(before.decision().valid && after.decision().valid);
    assert(before.decision().category == 5 && after.decision().category == 5);
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
    // Exact dyadic coordinates avoid treating decimal rounding as a test oracle.
    // Every accepted normal split conserves the interval and opaque identity.
    for (int start = -16; start <= 16; ++start) {
        for (int length = 1; length <= 16; ++length) {
            for (int step = 1; step < 16; ++step) {
                const double time = start + length * (step / 16.0);
                for (std::int64_t category = 1; category <= 5; ++category) {
                    const StageFragment input{category, static_cast<double>(start),
                                               static_cast<double>(start + length), -17};
                    auto split_case = splitStageFragment(input, time, SplitOrder::numeric_one);
                    assert(split_case.complete() && split_case.data()->left_valid && split_case.data()->right_valid);
                    const auto &left = split_case.data()->left;
                    const auto &right = split_case.data()->right;
                    assert(left.category == category && right.category == category);
                    assert(left.source_id == -17 && right.source_id == -17);
                    assert(left.start == input.start && left.end == time && right.start == time && right.end == input.end);
                    assert((left.end - left.start) + (right.end - right.start) == length);
                }
            }
        }
    }
}

static void testOrderedSourceSliceContribution() {
    using State = SliceInputState;
    SleepStageDurationReducer initial;
    const std::vector<StageFragment> ordered = {
        {2, 0, 20, 8}, {3, 0, 30, 9}, {4, 0, 10, 8}
    };
    auto result = accumulateOrderedSourceSlice(initial, ordered, 0, 30,
                                               State::ordered_valid_split_fragments);
    assert(result.complete() && result.data()->has_contributing_source);
    assert(result.data()->selected_source_id == 8);
    assert(result.data()->contributing_fragments == 2 && result.data()->other_source_fragments == 1);
    assert(result.data()->total.decision().category == 2); // Awake not deleted
    assert(initial.valid() && !initial.decision().has_stage); // caller bucket untouched
    assert(ordered[0].category == 2 && ordered[1].category == 3 && ordered[1].source_id == 9);
    // Supplied traversal changes first effective source; this primitive must not
    // replace it by numeric source order or an invented stable provider priority.
    auto reversed = accumulateOrderedSourceSlice(initial,
        {{3, 0, 30, 9}, {2, 0, 20, 8}}, 0, 30, State::ordered_valid_split_fragments);
    assert(reversed.complete() && reversed.data()->selected_source_id == 9);
    assert(reversed.data()->total.decision().category == 3);
    // A new advancement slice selects anew; statistics bucket duration and first
    // arrival sequence accumulate across slices on the copied total reducer.
    auto next = accumulateOrderedSourceSlice(result.data()->total, {{5, 30, 60, -1}}, 30, 60,
                                             State::ordered_valid_split_fragments);
    assert(next.complete() && next.data()->selected_source_id == -1);
    assert(next.data()->total.decision().category == 5);
    auto zero_source = accumulateOrderedSourceSlice(initial, {{3, 0, 1, 0}}, 0, 1,
                                                     State::ordered_valid_split_fragments);
    assert(zero_source.complete() && zero_source.data()->has_contributing_source && zero_source.data()->selected_source_id == 0);
    auto empty = accumulateOrderedSourceSlice(initial, {}, 0, 30, State::ordered_valid_split_fragments);
    assert(empty.complete() && !empty.data()->has_contributing_source && !empty.data()->total.decision().has_stage);
    assert(!accumulateOrderedSourceSlice(initial, ordered, 0, 30, State::unresolved_fragments).data());
    assert(!accumulateOrderedSourceSlice(initial, ordered, 0, 30, State::ordered_valid_split_fragments, 1).data());
    assert(!accumulateOrderedSourceSlice(initial, {}, 0, 0, State::ordered_valid_split_fragments).data());
    assert(!accumulateOrderedSourceSlice(initial, {{3, -1, 1, 1}}, 0, 30, State::ordered_valid_split_fragments).data());
    assert(!accumulateOrderedSourceSlice(initial, {{3, 0, 31, 1}}, 0, 30, State::ordered_valid_split_fragments).data());
    // Invalid trailing foreign-source input cannot be skipped into partial
    // success merely because that source wouldn't contribute to TOTAL.
    auto invalid = accumulateOrderedSourceSlice(initial, {{3, 0, 10, 1}, {99, 0, 1, 2}}, 0, 30,
                                                State::ordered_valid_split_fragments);
    assert(invalid.status() == SourceSliceStatus::invalid_fragment && !invalid.data());
    SleepStageDurationReducer bad_bucket;
    assert(!bad_bucket.add(6, 0, 1));
    assert(!accumulateOrderedSourceSlice(bad_bucket, {}, 0, 30, State::ordered_valid_split_fragments).data());
    const double maximum = std::numeric_limits<double>::max();
    SleepStageDurationReducer almost_full;
    assert(almost_full.add(3, 0, maximum));
    auto overflow = accumulateOrderedSourceSlice(almost_full, {{3, 0, maximum, 8}}, 0, maximum,
                                                 State::ordered_valid_split_fragments);
    assert(overflow.status() == SourceSliceStatus::invalid_accumulation && !overflow.data());
    assert(almost_full.valid()); // transactional failure didn't corrupt original
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
    // Threshold-preserving split can leave a valid WHOLE fragment that extends
    // outside the requested slice. Reject this combination; do not silently
    // clamp or claim a complete higher-level pipeline.
    auto short_split = splitStageFragment({3, 0, 1, 5}, 0.005, SplitOrder::numeric_one);
    assert(short_split.complete() && short_split.data()->right_valid);
    auto outside = accumulateOrderedSourceSlice(initial, {short_split.data()->right}, 0.005, 1,
                                                State::ordered_valid_split_fragments);
    assert(outside.status() == SourceSliceStatus::fragment_outside_slice && !outside.data());
    for (std::int64_t source : {0, -1}) {
        auto opaque = accumulateOrderedSourceSlice(initial,
            {{3, 0, 1, source}, {5, 0, 2, 99}, {4, 1, 3, source}}, 0, 3,
            State::ordered_valid_split_fragments);
        assert(opaque.complete() && opaque.data()->selected_source_id == source);
        assert(opaque.data()->contributing_fragments == 2 && opaque.data()->other_source_fragments == 1);
        assert(opaque.data()->total.decision().category == 4);
    }
    SleepStageDurationReducer existing;
    assert(existing.add(4, 0, 10));
    auto empty_existing = accumulateOrderedSourceSlice(existing, {}, 10, 20, State::ordered_valid_split_fragments);
    assert(empty_existing.complete() && !empty_existing.data()->has_contributing_source);
    assert(empty_existing.data()->total.decision().category == 4);
    auto tie_next = accumulateOrderedSourceSlice(existing, {{3, 10, 20, 5}}, 10, 20,
                                                 State::ordered_valid_split_fragments);
    assert(tie_next.complete() && tie_next.data()->total.decision().category == 4);
    const double denormal = std::numeric_limits<double>::denorm_min();
    auto tiny = accumulateOrderedSourceSlice(initial, {{3, 0, denormal, 5}}, 0, denormal,
                                             State::ordered_valid_split_fragments);
    assert(tiny.complete() && tiny.data()->has_contributing_source && tiny.data()->contributing_fragments == 1);
    assert(tiny.data()->total.decision().valid && !tiny.data()->total.decision().has_stage);
    auto short_left = splitStageFragment({3, 0, 1, 5}, 0.995, SplitOrder::numeric_zero);
    assert(short_left.complete() && short_left.data()->left_valid);
    auto outside_left = accumulateOrderedSourceSlice(initial, {short_left.data()->left}, 0, 0.995,
                                                      State::ordered_valid_split_fragments);
    assert(outside_left.status() == SourceSliceStatus::fragment_outside_slice && !outside_left.data());
    // All fixture traversals: source selection depends on supplied first valid
    // contribution, then preserves first-seen category ties within that source.
    const std::vector<StageFragment> candidates = {
        {2, 0, 1, 0}, {3, 0, 1, 1}, {4, 0, 1, 0}, {5, 0, 1, 1}
    };
    std::array<int, 4> traversal{{0, 1, 2, 3}};
    unsigned arrangements = 0;
    do {
        std::vector<StageFragment> supplied;
        for (int i : traversal) supplied.push_back(candidates[static_cast<std::size_t>(i)]);
        auto contribution = accumulateOrderedSourceSlice(initial, supplied, 0, 1,
                                                         State::ordered_valid_split_fragments);
        assert(contribution.complete() && contribution.data()->has_contributing_source);
        assert(contribution.data()->selected_source_id == supplied[0].source_id);
        assert(contribution.data()->contributing_fragments == 2 && contribution.data()->other_source_fragments == 2);
        assert(contribution.data()->total.decision().category == supplied[0].category);
        ++arrangements;
    } while (std::next_permutation(traversal.begin(), traversal.end()));
    assert(arrangements == 24);
    auto zero_limit = accumulateOrderedSourceSlice(initial, {}, 0, 1,
                                                    State::ordered_valid_split_fragments, 0);
    assert(zero_limit.status() == SourceSliceStatus::fragment_limit && !zero_limit.data());
}

static void testOrderedSlicesToBucketDecisionToLegacy() {
    // Explicit fixture-supplied traversal and bucket bounds, not a demonstration
    // that raw native source ordering/time-grid dispatch has been implemented.
    SleepStageDurationReducer bucket;
    auto left = accumulateOrderedSourceSlice(bucket,
        {{2, 0, 20, 8}, {3, 0, 30, 9}, {4, 0, 10, 8}}, 0, 30,
        SliceInputState::ordered_valid_split_fragments);
    assert(left.complete());
    auto right = accumulateOrderedSourceSlice(left.data()->total,
        {{5, 30, 60, 9}, {2, 30, 60, 8}}, 30, 60,
        SliceInputState::ordered_valid_split_fragments);
    assert(right.complete());
    auto first = right.data()->total.decision();
    assert(first.valid && first.has_stage && first.category == 5);
    SleepStageDurationReducer next_bucket;
    auto next = accumulateOrderedSourceSlice(next_bucket, {{2, 60, 120, 8}}, 60, 120,
                                               SliceInputState::ordered_valid_split_fragments);
    assert(next.complete());
    auto second = next.data()->total.decision();
    assert(second.valid && second.has_stage && second.category == 2);
    auto projected = projectLegacySleepSummary({{first.category, 0, 60}, {second.category, 60, 120}},
                                                StatisticsInputState::resolved_statistics_intervals);
    assert(projected.complete() && projected.data()->asleep_duration == 60);
    assert(projected.data()->asleep_segments.size() == 1);
    assert(projected.data()->asleep_segments[0].category == 1);
    assert(first.category == 5 && second.category == 2); // no raw category rewrite
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
}

static void testTargetPlanAndSingleAdvance() {
    auto rounded = planSourceMergeTarget(0, 45, 60, 30);
    assert(rounded.complete() && rounded.data()->target == 30 && rounded.data()->needs_advance);
    auto endpoint = planSourceMergeTarget(0, 60, 60, 30);
    assert(endpoint.complete() && endpoint.data()->target == 60 && endpoint.data()->needs_advance);
    auto beyond = planSourceMergeTarget(0, 75, 60, 30);
    assert(beyond.complete() && beyond.data()->target == 75);
    auto no_work = planSourceMergeTarget(31, 45, 60, 30);
    assert(no_work.complete() && no_work.data()->target == 30 && !no_work.data()->needs_advance);
    auto negative = planSourceMergeTarget(-61, -45, 0, 30);
    assert(negative.complete() && negative.data()->target == -60 && negative.data()->needs_advance);
    auto no_grid = planSourceMergeTarget(0, 45, 60, 0);
    assert(no_grid.complete() && no_grid.data()->target == 45);
    assert(!planSourceMergeTarget(0, 1, 2, -1).data());
    assert(!planSourceMergeTarget(0, 1, 2, std::numeric_limits<double>::quiet_NaN()).data());
    auto divide_overflow = planSourceMergeTarget(0, 1, 2, std::numeric_limits<double>::denorm_min());
    assert(divide_overflow.status() == TargetPlanStatus::nonfinite_arithmetic && !divide_overflow.data());

    SingleAdvanceConfiguration supported;
    supported.mask_is_empty = true; supported.separate_by_source = false;
    SleepStageDurationReducer initial;
    PendingStageFragment pending{{3, 0, 60, 7}, false, false, false};
    auto first = advanceSinglePendingTotal(initial, pending, 0, 30, supported);
    assert(first.complete() && first.data()->current == 30 && first.data()->has_pending);
    assert(first.data()->pending.fragment.start == 30 && first.data()->pending.fragment.end == 60);
    assert(first.data()->pending.fragment.category == 3 && first.data()->pending.fragment.source_id == 7);
    assert(first.data()->contributed && first.data()->native_total_count_argument);
    assert(first.data()->pending.history_flag && first.data()->pending.per_source_counted && first.data()->pending.total_counted);
    assert(!initial.decision().has_stage && pending.fragment.start == 0 && !pending.total_counted);
    auto end = advanceSinglePendingTotal(first.data()->total, first.data()->pending, 30, 60, supported);
    assert(end.complete() && end.data()->current == 60 && !end.data()->has_pending);
    assert(end.data()->pending.fragment.category == 0 && !end.data()->pending.history_flag);
    assert(end.data()->contributed && !end.data()->native_total_count_argument);
    assert(end.data()->total.decision().category == 3);

    // Tiny left side: no contribution, right and history flags unchanged, but
    // current advances even though fragment.start remains before it.
    auto left_invalid = advanceSinglePendingTotal(initial, {{5, 0, 1, 8}, true, false, true}, 0, 0.005, supported);
    assert(left_invalid.complete() && !left_invalid.data()->contributed && left_invalid.data()->has_pending);
    assert(left_invalid.data()->current == 0.005 && left_invalid.data()->pending.fragment.start == 0);
    assert(left_invalid.data()->pending.history_flag && !left_invalid.data()->pending.per_source_counted && left_invalid.data()->pending.total_counted);
    auto continued = advanceSinglePendingTotal(left_invalid.data()->total, left_invalid.data()->pending, 0.005, 0.5, supported);
    assert(continued.complete() && continued.data()->contributed && !continued.data()->native_total_count_argument);
    // Tiny right: whole left is counted; current still equals target, not end.
    auto right_invalid = advanceSinglePendingTotal(initial, pending, 0, 59.995, supported);
    assert(right_invalid.complete() && right_invalid.data()->current == 59.995 && !right_invalid.data()->has_pending);
    assert(right_invalid.data()->total.decision().category == 3);
    SingleAdvanceConfiguration missing;
    assert(advanceSinglePendingTotal(initial, pending, 0, 30, missing).status() == SingleAdvanceStatus::unsupported_nonempty_mask);
    missing.mask_is_empty = true;
    assert(advanceSinglePendingTotal(initial, pending, 0, 30, missing).status() == SingleAdvanceStatus::unsupported_source_ledger);
    assert(!advanceSinglePendingTotal(initial, pending, 0, 0, supported).data());
    SleepStageDurationReducer invalid_bucket;
    assert(!invalid_bucket.add(6, 0, 1));
    assert(advanceSinglePendingTotal(invalid_bucket, pending, 0, 30, supported).status() == SingleAdvanceStatus::invalid_bucket);
    auto beyond_fragment = advanceSinglePendingTotal(initial, pending, 0, 61, supported);
    assert(beyond_fragment.complete() && !beyond_fragment.data()->has_pending && beyond_fragment.data()->current == 61);
    assert(beyond_fragment.data()->contributed_fragment.end == 60);
    for (unsigned bits = 0; bits < 8; ++bits) {
        PendingStageFragment marked{{4, 0, 1, 13}, bool(bits & 1), bool(bits & 2), bool(bits & 4)};
        auto unchanged_flags = advanceSinglePendingTotal(initial, marked, 0, 0.005, supported);
        assert(unchanged_flags.complete() && !unchanged_flags.data()->contributed && unchanged_flags.data()->has_pending);
        assert(unchanged_flags.data()->pending.history_flag == marked.history_flag);
        assert(unchanged_flags.data()->pending.per_source_counted == marked.per_source_counted);
        assert(unchanged_flags.data()->pending.total_counted == marked.total_counted);
        auto set_flags = advanceSinglePendingTotal(initial, marked, 0, 0.5, supported);
        assert(set_flags.complete() && set_flags.data()->contributed && set_flags.data()->has_pending);
        assert(set_flags.data()->native_total_count_argument == !marked.total_counted);
        assert(set_flags.data()->pending.history_flag && set_flags.data()->pending.per_source_counted && set_flags.data()->pending.total_counted);
        assert(marked.fragment.start == 0 && marked.fragment.end == 1);
    }
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
}

static void testCalendarBucketOutputUsesWholeBounds() {
    SleepStageDurationReducer partial;
    assert(partial.add(3, 10, 20)); // contribution is10 seconds, bucket is60
    const CalendarBucketBounds bounds{0, 60};
    auto unfinalized = finalizeSleepStatisticsBucket(partial, bounds, false);
    assert(unfinalized.status() == BucketOutputStatus::not_finalized && !unfinalized.succeeded());
    auto complete = finalizeSleepStatisticsBucket(partial, bounds, true);
    assert(complete.succeeded() && complete.interval());
    assert(complete.interval()->category == 3 && complete.interval()->start == 0 && complete.interval()->end == 60);
    // Last bucket is not clipped to the contributor's end20.
    auto legacy = projectLegacySleepSummary({*complete.interval()}, StatisticsInputState::resolved_statistics_intervals);
    assert(legacy.complete() && legacy.data()->asleep_duration == 60);

    SleepStageDurationReducer awake;
    assert(awake.add(2, 65, 70));
    auto awake_bucket = finalizeSleepStatisticsBucket(awake, {60, 120}, true);
    assert(awake_bucket.succeeded() && awake_bucket.interval() && awake_bucket.interval()->category == 2);
    auto both = projectLegacySleepSummary({*complete.interval(), *awake_bucket.interval()},
                                           StatisticsInputState::resolved_statistics_intervals);
    assert(both.complete() && both.data()->asleep_duration == 60);
    // Supplied calendar boundaries need not be fixed60-second arithmetic.
    auto nonuniform = finalizeSleepStatisticsBucket(partial, {-4000, -3939}, true);
    assert(nonuniform.succeeded() && nonuniform.interval()->start == -4000 && nonuniform.interval()->end == -3939);
    assert(projectLegacySleepSummary({*nonuniform.interval()}, StatisticsInputState::resolved_statistics_intervals).data()->asleep_duration == 61);
    SleepStageDurationReducer empty;
    auto no_stage = finalizeSleepStatisticsBucket(empty, bounds, true);
    assert(no_stage.succeeded() && no_stage.status() == BucketOutputStatus::no_prevailing_stage && !no_stage.interval());
    SleepStageDurationReducer bad;
    assert(!bad.add(6, 0, 1));
    auto invalid = finalizeSleepStatisticsBucket(bad, bounds, true);
    assert(!invalid.succeeded() && invalid.status() == BucketOutputStatus::invalid_reducer && !invalid.interval());
    for (auto invalid_bounds : {CalendarBucketBounds{1, 1}, CalendarBucketBounds{2, 1},
                               CalendarBucketBounds{0, std::numeric_limits<double>::infinity()},
                               CalendarBucketBounds{-std::numeric_limits<double>::max(), std::numeric_limits<double>::max()}}) {
        auto rejected = finalizeSleepStatisticsBucket(partial, invalid_bounds, true);
        assert(!rejected.succeeded() && rejected.status() == BucketOutputStatus::invalid_bounds && !rejected.interval());
    }
    SleepStageDurationReducer in_bed;
    assert(in_bed.add(0, 0, 30));
    auto separate = finalizeSleepStatisticsBucket(in_bed, bounds, true);
    assert(!separate.succeeded() && separate.status() == BucketOutputStatus::in_bed_category_not_supported);
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
}

static void testSinglePendingToCompleteCalendarBucket() {
    // Only the audited empty-mask TOTAL path is composed here. The caller
    // explicitly supplies real-equivalent bounds and one source's pending item;
    // this does not implement calendar lookup or arbitrary raw-source dispatch.
    SleepStageDurationReducer initial;
    PendingStageFragment pending{{4, 0, 60, 17}, false, false, false};
    SingleAdvanceConfiguration configuration;
    configuration.mask_is_empty = true;
    configuration.separate_by_source = false;
    auto target = planSourceMergeTarget(0, 45, 60, 30);
    assert(target.complete() && target.data()->needs_advance && target.data()->target == 30);
    auto first = advanceSinglePendingTotal(initial, pending, 0, target.data()->target, configuration);
    assert(first.complete() && first.data()->has_pending && first.data()->current == 30);
    auto finish_target = planSourceMergeTarget(first.data()->current, 60, 60, 30);
    assert(finish_target.complete() && finish_target.data()->target == 60);
    auto finished = advanceSinglePendingTotal(first.data()->total, first.data()->pending,
                                               first.data()->current, finish_target.data()->target, configuration);
    assert(finished.complete() && !finished.data()->has_pending && finished.data()->current == 60);
    auto bucket = finalizeSleepStatisticsBucket(finished.data()->total, {0, 60}, true);
    assert(bucket.succeeded() && bucket.interval() && bucket.interval()->category == 4);
    auto projected = projectLegacySleepSummary({*bucket.interval()}, StatisticsInputState::resolved_statistics_intervals);
    assert(projected.complete() && projected.data()->asleep_duration == 60);
    assert(projected.data()->asleep_segments[0].category == 1);
    assert(pending.fragment.category == 4 && pending.fragment.start == 0 && !pending.history_flag);
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
}

int main() {
    testSplits(); testAdvance(); testSplitFeedsReducerWithoutCategoryScaling();
    testOrderedSourceSliceContribution();
    testOrderedSlicesToBucketDecisionToLegacy();
    testTargetPlanAndSingleAdvance();
    testCalendarBucketOutputUsesWholeBounds();
    testSinglePendingToCompleteCalendarBucket();
    std::puts("PASS HealthSupport finite split/grid primitives/not complete source pipeline");
}
