#include "SleepRawAdmission.hpp"
#include "ModuleReadiness.hpp"
#include <cassert>
#include <cstdio>
#include <limits>

using namespace watchfix::healthsupport;

int main() {
    const CalendarBucketBounds bucket{0, 60};
    const StageFragment raw{4, -30, 90, 17};
    auto plan = planRawStageAdmission(raw, bucket, true, SplitOrder::numeric_one);
    assert(plan.complete() && plan.data()->has_pending && plan.data()->has_carry);
    assert(plan.data()->pending.fragment.category == 4 && plan.data()->pending.fragment.source_id == 17);
    assert(plan.data()->pending.fragment.start == 0 && plan.data()->pending.fragment.end == 60);
    assert(plan.data()->carry.start == 60 && plan.data()->carry.end == 90);
    assert(plan.data()->carry.category == 4 && plan.data()->carry.source_id == 17);
    assert(!plan.data()->pending.history_flag && !plan.data()->pending.per_source_counted && !plan.data()->pending.total_counted);
    assert(plan.data()->advance_existing_before_enqueue && plan.data()->requested_advance_target == 0);
    assert(raw.start == -30 && raw.end == 90); // unchanged raw input

    auto no_advance = planRawStageAdmission(raw, bucket, false, SplitOrder::numeric_one);
    assert(no_advance.complete() && !no_advance.data()->advance_existing_before_enqueue);
    assert(no_advance.data()->requested_advance_target == 0);
    auto inside = planRawStageAdmission({3, 10, 20, 5}, bucket, true, SplitOrder::numeric_one);
    assert(inside.complete() && inside.data()->has_pending && !inside.data()->has_carry);
    assert(inside.data()->pending.fragment.start == 10 && inside.data()->pending.fragment.end == 20);
    assert(inside.data()->requested_advance_target == 10);
    auto before = planRawStageAdmission({3, -30, -10, 5}, bucket, true, SplitOrder::numeric_one);
    assert(before.complete() && !before.data()->has_pending && !before.data()->has_carry);
    assert(!before.data()->advance_existing_before_enqueue && before.data()->carry.category == 0);
    auto after = planRawStageAdmission({5, 70, 90, 8}, bucket, true, SplitOrder::numeric_one);
    assert(after.complete() && !after.data()->has_pending && after.data()->has_carry);
    assert(after.data()->carry.start == 70 && !after.data()->advance_existing_before_enqueue);

    // Start-boundary threshold can preserve whole raw slightly before bucket.
    auto near_start = planRawStageAdmission({3, -0.005, -0.001, 5}, bucket, true, SplitOrder::numeric_one);
    assert(near_start.complete() && near_start.data()->has_pending && !near_start.data()->has_carry);
    assert(near_start.data()->pending.fragment.start == -0.005 && near_start.data()->pending.fragment.end == -0.001);
    assert(near_start.data()->requested_advance_target == -0.005); // no max(current,start)
    // End numeric1 can retain whole carry before bucket.end; numeric0 retains
    // whole left on both-short sides. Neither result is generic intersection.
    auto short_one = planRawStageAdmission({3, 59.995, 60.005, 5}, bucket, true, SplitOrder::numeric_one);
    auto short_zero = planRawStageAdmission({3, 59.995, 60.005, 5}, bucket, true, SplitOrder::numeric_zero);
    assert(short_one.complete() && !short_one.data()->has_pending && short_one.data()->has_carry);
    assert(short_one.data()->carry.start == 59.995);
    assert(short_zero.complete() && short_zero.data()->has_pending && !short_zero.data()->has_carry);
    assert(short_zero.data()->pending.fragment.end == 60.005);
    auto next = planRawStageAdmission(short_one.data()->carry, {60, 120}, true, SplitOrder::numeric_one);
    assert(next.complete() && next.data()->has_pending && next.data()->pending.fragment.start == 59.995);
    assert(!next.data()->pending.history_flag && !next.data()->pending.per_source_counted && !next.data()->pending.total_counted);

    for (std::int64_t category : {-1, 0, 6}) {
        auto rejected = planRawStageAdmission({category, 0, 1, 1}, bucket, true, SplitOrder::numeric_one);
        assert(rejected.status() == RawAdmissionStatus::invalid_fragment && !rejected.data());
    }
    assert(!planRawStageAdmission({3, 0, 0, 1}, bucket, true, SplitOrder::numeric_one).data());
    assert(!planRawStageAdmission(raw, {1, 1}, true, SplitOrder::numeric_one).data());
    assert(!planRawStageAdmission(raw, {0, std::numeric_limits<double>::infinity()}, true, SplitOrder::numeric_one).data());
    assert(planRawStageAdmission(raw, bucket, true, static_cast<SplitOrder>(2)).status() == RawAdmissionStatus::invalid_end_split_order);
    // Ordinary integer endpoints: plan validity/identity and conserved output
    // inside+carry duration after dropping the strict pre-bucket portion.
    for (int start = -10; start <= 70; ++start) for (int duration = 1; duration <= 10; ++duration) {
        const StageFragment input{5, double(start), double(start + duration), -2};
        auto split = planRawStageAdmission(input, bucket, true, SplitOrder::numeric_one);
        assert(split.complete());
        double retained = 0;
        if (split.data()->has_pending) {
            const auto &fragment = split.data()->pending.fragment;
            assert(fragment.category == 5 && fragment.source_id == -2);
            retained += fragment.end - fragment.start;
        }
        if (split.data()->has_carry) {
            const auto &fragment = split.data()->carry;
            assert(fragment.category == 5 && fragment.source_id == -2);
            retained += fragment.end - fragment.start;
        }
        const double expected = input.end <= 0 ? 0 : input.end - std::max(0.0, input.start);
        assert(retained == expected);
    }
    assert(!ModuleReadiness::may_expand_sleep_acceptance());
    std::puts("PASS raw bucket admission/two-boundary split semantics/raw-only carry/reset flags/no intersection shortcut");
}
