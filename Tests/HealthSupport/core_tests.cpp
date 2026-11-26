// Synthetic module-core tests only. No native HealthKit data or device calls.
#include "ModuleReadiness.hpp"
#include "SleepStageDurationReducer.hpp"
#include "LegacyDerivedSummary.hpp"

#include <algorithm>
#include <cassert>
#include <cstdio>
#include <limits>

using namespace watchfix::healthsupport;

static void testClosedGate() {
    static_assert(!ModuleReadiness::runtime_implemented, "runtime must not exist yet");
    static_assert(!ModuleReadiness::installable, "core-only module is not installable");
    static_assert(!ModuleReadiness::enabled_by_default, "default must remain disabled");
    static_assert(!ModuleReadiness::may_expand_sleep_acceptance(), "acceptance must remain native");
    static_assert(ModuleReadiness::missing_capabilities == 63, "all unresolved runtime capabilities recorded");
    const std::int64_t values[] = {std::numeric_limits<std::int64_t>::min(), -1, 0, 1, 2, 3, 4, 5, 6,
                                   std::numeric_limits<std::int64_t>::max()};
    for (auto value : values) for (bool is_sleep : {false, true}) for (bool native : {false, true}) {
        assert(moduleAcceptanceDecision(native, is_sleep, value) == native);
    }
}

static void testReducer() {
    using Reducer = SleepStageDurationReducer;
    Reducer empty;
    assert(empty.valid() && empty.prevailing() == Reducer::no_stage);
    std::array<int, 6> order{{0, 1, 2, 3, 4, 5}};
    unsigned permutations = 0;
    do {
        Reducer reducer;
        for (int category : order) assert(reducer.add(category, 0, 10));
        assert(reducer.prevailing() == order[0]);
        ++permutations;
    } while (std::next_permutation(order.begin(), order.end()));
    assert(permutations == 720);
    Reducer repeated;
    assert(repeated.add(5, 0, 5) && repeated.add(3, 0, 6));
    assert(repeated.prevailing() == 3);
    assert(repeated.add(5, 5, 6) && repeated.prevailing() == 5);
    Reducer zero_first;
    assert(zero_first.add(4, 0, 0) && zero_first.add(2, 0, 1) && zero_first.add(4, 0, 1));
    assert(zero_first.prevailing() == 4);
    Reducer awake;
    assert(awake.add(3, 0, 10) && awake.add(2, 0, 20));
    assert(awake.prevailing() == 2);  // Awake retained through statistics.
    Reducer threshold;
    assert(threshold.add(3, 0, std::numeric_limits<double>::min()));
    assert(threshold.prevailing() == Reducer::no_stage);
    assert(threshold.add(3, 0, std::numeric_limits<double>::min()));
    assert(threshold.prevailing() == 3);
    for (int value : {-1, 6, 99}) {
        Reducer bad;
        assert(!bad.add(value, 0, 1) && !bad.valid());
        assert(!bad.add(3, 0, 1) && bad.prevailing() == Reducer::no_stage);
    }
    Reducer backwards, nonfinite, overflow;
    assert(!backwards.add(3, 2, 1));
    assert(!nonfinite.add(3, 0, std::numeric_limits<double>::quiet_NaN()));
    assert(!overflow.add(3, -std::numeric_limits<double>::max(), std::numeric_limits<double>::max()));
}

static LegacyProjection project(const std::vector<StageStatisticsInterval> &intervals,
                                ProjectionConfiguration configuration = ProjectionConfiguration()) {
    return projectLegacySleepSummary(intervals, StatisticsInputState::resolved_statistics_intervals, configuration);
}

static void requireFailure(const LegacyProjection &result, ProjectionStatus status) {
    assert(result.status() == status && !result.complete());
    assert(result.data() == nullptr);
}

static void testProjection() {
    const std::vector<StageStatisticsInterval> inputs = {
        {3, 0, 10}, {2, 10, 20}, {4, 20, 30}, {5, 30, 40}, {1, 100, 110}
    };
    const auto result = project(inputs);
    assert(result.complete() && result.data()->asleep_duration == 40);
    assert(result.data()->asleep_segments.size() == 2);
    const auto &first = result.data()->asleep_segments[0];
    assert(first.category == 1 && first.start == 0 && first.end == 40);
    assert(first.sample_intervals.size() == 2);
    assert(first.sample_intervals[0].start == 0 && first.sample_intervals[0].end == 10);
    assert(first.sample_intervals[1].start == 20 && first.sample_intervals[1].end == 40);
    // Bounding segment crosses Awake, but union sample duration excludes it.
    assert(result.data()->asleep_segments[1].start == 100 && result.data()->asleep_segments[1].end == 110);
    assert(inputs[0].category == 3 && inputs[1].category == 2 && inputs[2].category == 4);
    assert(inputs[3].category == 5 && inputs[4].category == 1); // raw fixture unchanged

    auto joined = project({{3, 0, 1}, {4, 30, 31}}); // exact default29s grouping gap
    assert(joined.complete() && joined.data()->asleep_segments.size() == 1 && joined.data()->asleep_duration == 2);
    assert(joined.data()->asleep_segments[0].sample_intervals.size() == 2);
    auto split = project({{3, 0, 1}, {4, 31, 32}});
    assert(split.complete() && split.data()->asleep_segments.size() == 2);
    assert(project({}).complete() && project({}).data()->asleep_segments.empty());
    assert(project({{2, 0, 10}}).complete() && project({{2, 0, 10}}).data()->asleep_duration == 0);

    for (auto zero : std::vector<std::vector<StageStatisticsInterval>>{
        {{3, 0, 0}}, {{3, 0, 1}, {4, 30, 30}, {5, 59, 60}},
        {{3, 0, 1}, {4, 1, 1}}, {{3, 0, 10}, {4, 5, 5}}, {{2, 0, 0}}})
        requireFailure(project(zero), ProjectionStatus::invalid_interval);
    ProjectionConfiguration touching;
    touching.maximum_combination_gap = 0;
    auto adjacent = project({{3, 0, 1}, {4, 1, 2}}, touching);
    assert(adjacent.complete() && adjacent.data()->asleep_segments.size() == 1);
    assert(adjacent.data()->asleep_segments[0].sample_intervals.size() == 1);

    requireFailure(projectLegacySleepSummary(inputs, StatisticsInputState::unresolved_raw_samples),
                   ProjectionStatus::unresolved_statistics);
    for (std::int64_t category : {-1, 0, 6})
        requireFailure(project({{category, 0, 1}}), ProjectionStatus::invalid_category);
    requireFailure(project({{3, 0, 10}, {2, 5, 6}}), ProjectionStatus::unordered_or_overlapping_statistics);
    requireFailure(project({{3, 10, 20}, {5, 0, 1}}), ProjectionStatus::unordered_or_overlapping_statistics);
    requireFailure(project({{3, 2, 1}}), ProjectionStatus::invalid_interval);
    requireFailure(project({{3, 0, std::numeric_limits<double>::infinity()}}), ProjectionStatus::invalid_interval);
    // Invalid final interval must not publish an earlier partial summary.
    requireFailure(project({{3, 0, 10}, {9, 10, 20}}), ProjectionStatus::invalid_category);
    ProjectionConfiguration invalid;
    invalid.maximum_combination_gap = -1;
    requireFailure(project(inputs, invalid), ProjectionStatus::invalid_configuration);
    invalid.maximum_combination_gap = std::numeric_limits<double>::quiet_NaN();
    requireFailure(project(inputs, invalid), ProjectionStatus::invalid_configuration);
    invalid.maximum_combination_gap = std::numeric_limits<double>::infinity();
    requireFailure(project({}, invalid), ProjectionStatus::invalid_configuration);
    ProjectionConfiguration limited;
    limited.maximum_intervals = 1;
    requireFailure(project(inputs, limited), ProjectionStatus::input_limit);
    limited.maximum_intervals = 0;
    requireFailure(project(inputs, limited), ProjectionStatus::invalid_configuration);
    const double maximum = std::numeric_limits<double>::max();
    requireFailure(project({{3, -maximum, 0}, {4, 0, maximum}}), ProjectionStatus::invalid_accumulated_duration);
    ProjectionConfiguration huge;
    huge.maximum_combination_gap = maximum;
    requireFailure(project({{3, -maximum, -maximum / 2}, {4, maximum / 2, maximum}}, huge),
                   ProjectionStatus::invalid_bounding_span);
    auto huge_gap = project({{3, -maximum, -maximum / 2}, {4, maximum / 2, maximum}});
    assert(huge_gap.complete() && huge_gap.data()->asleep_segments.size() == 2);
    ProjectionConfiguration exact;
    exact.maximum_intervals = 1;
    assert(project({{3, 0, 1}}, exact).complete());

    SleepStageDurationReducer invalid_after_success;
    assert(invalid_after_success.add(3, 0, 1) && invalid_after_success.decision().has_stage);
    assert(!invalid_after_success.add(3, 0, std::numeric_limits<double>::infinity()));
    assert(!invalid_after_success.decision().valid && !invalid_after_success.decision().has_stage);
    SleepStageDurationReducer accumulated;
    assert(accumulated.add(3, 0, maximum));
    assert(!accumulated.add(3, 0, maximum) && !accumulated.decision().valid);
}

static void testResolvedBucketToLegacyProjection() {
    // Synthetic, explicitly preselected fragments only. No source selection is
    // inferred by this test. Preserve Awake until each bucket decision finishes.
    SleepStageDurationReducer first_bucket, second_bucket;
    assert(first_bucket.add(3, 0, 10) && first_bucket.add(2, 0, 20));
    assert(second_bucket.add(4, 30, 50) && second_bucket.add(5, 30, 40));
    const auto first = first_bucket.decision(), second = second_bucket.decision();
    assert(first.valid && first.has_stage && first.category == 2);
    assert(second.valid && second.has_stage && second.category == 4);
    auto legacy = project({{first.category, 0, 30}, {second.category, 30, 60}});
    assert(legacy.complete() && legacy.data()->asleep_duration == 30);
    assert(legacy.data()->asleep_segments.size() == 1);
    assert(legacy.data()->asleep_segments[0].category == 1); // derived view only
    assert(first.category == 2 && second.category == 4); // decisions unmodified
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
}

int main() {
    testClosedGate();
    testReducer();
    testProjection();
    testResolvedBucketToLegacyProjection();
    std::puts("PASS HealthSupport offline core/closed gate/720 orders/resolved projection/no device");
}
