// Finite-input outer-target planning and single-pending TOTAL-only transition.
// No native object layout, calendar calls, source sorting, callbacks or hooks.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_ADVANCE_DISPATCH_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_ADVANCE_DISPATCH_HPP

#include "NumericPolicy.hpp"
#include "SleepStageFragments.hpp"
#include "SleepStageDurationReducer.hpp"
#include <cmath>

namespace watchfix { namespace healthsupport {

enum class TargetPlanStatus { complete, invalid_input, nonfinite_arithmetic };
struct TargetPlanData { double target; bool needs_advance; };
class TargetPlanResult;
TargetPlanResult planSourceMergeTarget(double, double, double, double) noexcept;

class TargetPlanResult {
public:
    TargetPlanStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == TargetPlanStatus::complete; }
    const TargetPlanData *data() const noexcept { return complete() ? &data_ : nullptr; }
private:
    TargetPlanStatus status_ = TargetPlanStatus::invalid_input;
    TargetPlanData data_{0, false};
    friend TargetPlanResult planSourceMergeTarget(double, double, double, double) noexcept;
};

// interval_end is the bucket's stored end, not the sleep day's assumed24h end.
// Native rounds only if g>0 AND interval_end>target. It does not round at the
// interval endpoint or for an overshooting target; do not silently clamp either.
inline TargetPlanResult planSourceMergeTarget(double current, double requested_target,
                                               double interval_end, double granularity) noexcept {
    TargetPlanResult result;
    if (!std::isfinite(current) || !std::isfinite(requested_target) ||
        !std::isfinite(interval_end) || !std::isfinite(granularity) || granularity < 0) return result;
    double target = requested_target;
    if (granularity > 0 && interval_end > requested_target) {
        const double units = requested_target / granularity;
        if (!std::isfinite(units)) {
            result.status_ = TargetPlanStatus::nonfinite_arithmetic;
            return result;
        }
        target = granularity * std::floor(units);
        if (!std::isfinite(target)) {
            result.status_ = TargetPlanStatus::nonfinite_arithmetic;
            return result;
        }
    }
    result.data_ = {target, current < target};
    result.status_ = TargetPlanStatus::complete;
    return result;
}

struct PendingStageFragment {
    StageFragment fragment;
    // Names intentionally avoid inventing a business meaning for native H.
    bool history_flag;
    bool per_source_counted;
    bool total_counted;
};

enum class SingleAdvanceStatus {
    complete,
    invalid_bucket,
    invalid_advance,
    unsupported_nonempty_mask,
    unsupported_source_ledger,
    split_rejected,
    accumulation_failed
};

struct SingleAdvanceConfiguration {
    // No sample mask or source-key mapping is inferred or implemented here.
    bool mask_is_empty = false;
    bool separate_by_source = true;
};

struct SingleAdvanceData {
    SleepStageDurationReducer total;
    double current = 0;
    bool has_pending = false;
    PendingStageFragment pending{{0, 0, 0, 0}, false, false, false};
    bool contributed = false;
    // Valid only when contributed=true. Used by the separate source-ledger
    // transition so it consumes exactly the same threshold-preserved fragment.
    StageFragment contributed_fragment{0, 0, 0, 0};
    // Report only the audited boolean argument. The finite reducer does not
    // implement the native sample-count field, so do not claim counter parity.
    bool native_total_count_argument = false;
};

class SingleAdvanceResult;
SingleAdvanceResult advanceSinglePendingTotal(const SleepStageDurationReducer &,
    const PendingStageFragment &, double, double, SingleAdvanceConfiguration) noexcept;

class SingleAdvanceResult {
public:
    SingleAdvanceStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == SingleAdvanceStatus::complete; }
    const SingleAdvanceData *data() const noexcept { return complete() ? &data_ : nullptr; }
private:
    SingleAdvanceStatus status_ = SingleAdvanceStatus::invalid_advance;
    SingleAdvanceData data_;
    friend SingleAdvanceResult advanceSinglePendingTotal(const SleepStageDurationReducer &,
        const PendingStageFragment &, double, double, SingleAdvanceConfiguration) noexcept;
};

// One valid pending fragment only, empty mask, TOTAL-only. All caller state is
// const; success publishes the copied state, failure exposes no partial payload.
// Current is NOT used to trim fragment.start. Native retains full short-side
// fragments; this transition must not impose the strict slice containment used
// by the separate multi-sample contribution primitive.
// bucket, pending and current must belong to one genuine progression history.
// Scalar checks cannot establish that provenance or prevent a caller replay.
inline SingleAdvanceResult advanceSinglePendingTotal(
    const SleepStageDurationReducer &bucket, const PendingStageFragment &pending,
    double current, double target, SingleAdvanceConfiguration configuration) noexcept {
    SingleAdvanceResult result;
    if (!bucket.valid()) { result.status_ = SingleAdvanceStatus::invalid_bucket; return result; }
    if (!std::isfinite(current) || !std::isfinite(target) || target <= current ||
        !std::isfinite(target - current)) return result;
    if (!configuration.mask_is_empty) {
        result.status_ = SingleAdvanceStatus::unsupported_nonempty_mask;
        return result;
    }
    if (configuration.separate_by_source) {
        result.status_ = SingleAdvanceStatus::unsupported_source_ledger;
        return result;
    }
    // Fast path may receive a target outside the pending interval. Preserve the
    // whole valid side with the audited threshold order; never clamp its dates.
    auto split = splitStageFragmentAtAdvanceBoundary(pending.fragment, target, SplitOrder::numeric_one);
    if (!split.complete()) { result.status_ = SingleAdvanceStatus::split_rejected; return result; }
    SingleAdvanceData candidate;
    candidate.total = bucket;
    candidate.current = target; // native fast path uses target, NOT left.end
    candidate.has_pending = split.data()->right_valid;
    if (candidate.has_pending) {
        candidate.pending = pending;
        candidate.pending.fragment = split.data()->right;
    }
    if (split.data()->left_valid) {
        const auto &left = split.data()->left;
        if (!candidate.total.add(left.category, left.start, left.end)) {
            result.status_ = SingleAdvanceStatus::accumulation_failed;
            return result;
        }
        candidate.contributed = true;
        candidate.contributed_fragment = left;
        candidate.native_total_count_argument = !pending.total_counted;
        if (candidate.has_pending) {
            // Native sets S even when SeparateBySource is off. Do not "fix" it.
            candidate.pending.history_flag = true;
            candidate.pending.per_source_counted = true;
            candidate.pending.total_counted = true;
        }
    }
    result.data_ = candidate;
    result.status_ = SingleAdvanceStatus::complete;
    return result;
}

} }
#endif
