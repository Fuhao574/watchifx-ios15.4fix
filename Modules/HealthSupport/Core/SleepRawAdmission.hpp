// Raw-valid stage -> bucket admission plan, with two audited split operations.
// No native sample read/write, source lookup, calendar calculation or runtime.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_RAW_ADMISSION_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_RAW_ADMISSION_HPP

#include "SleepAdvanceDispatch.hpp"
#include "SleepStatisticsBucketOutput.hpp"
#include <cmath>

namespace watchfix { namespace healthsupport {

enum class RawAdmissionStatus {
    complete,
    invalid_bucket,
    invalid_fragment,
    invalid_end_split_order,
    split_failed
};

struct RawAdmissionData {
    bool has_pending = false;
    PendingStageFragment pending{{0, 0, 0, 0}, false, false, false};
    // RAW carry only. H/S/A and source mappings never travel across buckets.
    bool has_carry = false;
    StageFragment carry{0, 0, 0, 0};
    // Real execution must register the new source before advancing old pending,
    // then enqueue the new pending AFTER that advance, and create source ledger
    // entries afterward. This struct is a plan, not proof of that execution.
    bool advance_existing_before_enqueue = false;
    double requested_advance_target = 0;
};

class RawAdmissionResult;
RawAdmissionResult planRawStageAdmission(const StageFragment &, CalendarBucketBounds,
                                        bool, SplitOrder) noexcept;

class RawAdmissionResult {
public:
    RawAdmissionStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == RawAdmissionStatus::complete; }
    const RawAdmissionData *data() const noexcept { return complete() ? &data_ : nullptr; }
private:
    RawAdmissionStatus status_ = RawAdmissionStatus::invalid_fragment;
    RawAdmissionData data_;
    friend RawAdmissionResult planRawStageAdmission(const StageFragment &, CalendarBucketBounds,
                                                   bool, SplitOrder) noexcept;
};

// start always uses numeric1. End order must come from audited bucket config;
// standard intervalCollection uses numeric1, not the multi-advance numeric0.
// Never clip whole-surviving sides to the bucket's endpoints or current time.
inline RawAdmissionResult planRawStageAdmission(const StageFragment &raw,
                                                 CalendarBucketBounds bounds,
                                                 bool advance_before_enqueue,
                                                 SplitOrder end_order) noexcept {
    RawAdmissionResult result;
    if (!std::isfinite(bounds.start) || !std::isfinite(bounds.end) || bounds.end <= bounds.start ||
        !std::isfinite(bounds.end - bounds.start)) {
        result.status_ = RawAdmissionStatus::invalid_bucket; return result;
    }
    if (raw.category < 1 || raw.category > 5 || !std::isfinite(raw.start) || !std::isfinite(raw.end) ||
        raw.end <= raw.start || !std::isfinite(raw.end - raw.start)) return result;
    if (end_order != SplitOrder::numeric_zero && end_order != SplitOrder::numeric_one) {
        result.status_ = RawAdmissionStatus::invalid_end_split_order; return result;
    }
    auto at_start = splitStageFragmentAtAdvanceBoundary(raw, bounds.start, SplitOrder::numeric_one);
    if (!at_start.complete()) { result.status_ = RawAdmissionStatus::split_failed; return result; }
    RawAdmissionData candidate;
    if (at_start.data()->right_valid) {
        // Native repeats split on an invalid middle too, but invalid raw never
        // becomes valid. Our representation forbids consuming invalid-side
        // fields, so the no-right case is directly an empty complete plan.
        const auto &middle = at_start.data()->right;
        auto at_end = splitStageFragmentAtAdvanceBoundary(middle, bounds.end, end_order);
        if (!at_end.complete()) { result.status_ = RawAdmissionStatus::split_failed; return result; }
        candidate.has_pending = at_end.data()->left_valid;
        candidate.has_carry = at_end.data()->right_valid;
        if (candidate.has_pending) {
            candidate.pending.fragment = at_end.data()->left;
            // Constructor defaults H/S/A false regardless of prior bucket flags.
            candidate.advance_existing_before_enqueue = advance_before_enqueue &&
                                                        candidate.pending.fragment.start < bounds.end;
            if (candidate.advance_existing_before_enqueue)
                candidate.requested_advance_target = candidate.pending.fragment.start;
        }
        if (candidate.has_carry) candidate.carry = at_end.data()->right;
    }
    result.data_ = candidate;
    result.status_ = RawAdmissionStatus::complete;
    return result;
}

} }
#endif
