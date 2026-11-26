// Independently written finite-input split primitive. No Apple structure layout,
// raw sample mutation, persistence, HealthKit calls or runtime entry point.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_STAGE_FRAGMENTS_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_STAGE_FRAGMENTS_HPP

#include "NumericPolicy.hpp"

#include <cmath>
#include <cstdint>

namespace watchfix { namespace healthsupport {

struct StageFragment {
    std::int64_t category;
    double start;
    double end;
    std::int64_t source_id;
};

// Only numeric0/1 are exposed; the native enum's business names are not proven.
// Native's other-value branch is NOT permission to accept arbitrary modes here.
enum class SplitOrder {
    numeric_zero = 0,
    numeric_one = 1
};

enum class FragmentSplitStatus {
    complete,
    invalid_fragment,
    invalid_split_time,
    unsupported_split_order
};

struct FragmentSplitData {
    // Invalid-side fields are module placeholders, not native byte-compatible
    // pair/in-place output. MUST NOT be consumed without the validity flag.
    bool left_valid = false;
    bool right_valid = false;
    StageFragment left{0, 0, 0, 0};
    StageFragment right{0, 0, 0, 0};
};

class FragmentSplitResult;
FragmentSplitResult splitStageFragment(const StageFragment &, double, SplitOrder) noexcept;
FragmentSplitResult splitStageFragmentAtAdvanceBoundary(const StageFragment &, double, SplitOrder) noexcept;

class FragmentSplitResult {
public:
    FragmentSplitStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == FragmentSplitStatus::complete; }
    const FragmentSplitData *data() const noexcept { return complete() ? &data_ : nullptr; }
private:
    FragmentSplitStatus status_ = FragmentSplitStatus::invalid_fragment;
    FragmentSplitData data_;
    friend FragmentSplitResult splitStageFragment(const StageFragment &, double, SplitOrder) noexcept;
    friend FragmentSplitResult splitStageFragmentAtAdvanceBoundary(const StageFragment &, double, SplitOrder) noexcept;
};

// A native advance may pass a boundary before/after a pending fragment. Such a
// split preserves the whole surviving side, rather than inventing/clamping dates.
// Both delta computations must still be finite; empty/invalid raw stays rejected.
inline FragmentSplitResult splitStageFragmentAtAdvanceBoundary(const StageFragment &fragment, double time,
                                               SplitOrder order) noexcept {
    FragmentSplitResult result;
    // InBed0 is a separate native branch. This primitive accepts only finite,
    // positive stage/Awake intervals; invalid/empty raw native samples are not
    // reproduced or silently normalized into a valid fragment.
    if (fragment.category < 1 || fragment.category > 5 ||
        !std::isfinite(fragment.start) || !std::isfinite(fragment.end) ||
        fragment.end <= fragment.start || !std::isfinite(fragment.end - fragment.start)) return result;
    if (!std::isfinite(time)) {
        result.status_ = FragmentSplitStatus::invalid_split_time;
        return result;
    }
    if (order != SplitOrder::numeric_zero && order != SplitOrder::numeric_one) {
        result.status_ = FragmentSplitStatus::unsupported_split_order;
        return result;
    }
    const double left = time - fragment.start;
    const double whole = fragment.end - fragment.start;
    // Keep audited evaluation order; whole-left need not be bitwise identical
    // to end-time when operands have very different magnitudes.
    const double right = whole - left;
    if (!std::isfinite(left) || !std::isfinite(right)) {
        result.status_ = FragmentSplitStatus::invalid_split_time;
        return result;
    }
    const double minimum_side = 0.01;
    enum class Placement { left, right, both } placement = Placement::both;
    if (order == SplitOrder::numeric_one) {
        if (left < minimum_side) placement = Placement::right;
        else if (right < minimum_side) placement = Placement::left;
    } else {
        if (right < minimum_side) placement = Placement::left;
        else if (left < minimum_side) placement = Placement::right;
    }
    result.data_.left_valid = placement != Placement::right;
    result.data_.right_valid = placement != Placement::left;
    if (result.data_.left_valid) {
        result.data_.left = fragment;
        if (placement == Placement::both) result.data_.left.end = time;
    }
    if (result.data_.right_valid) {
        result.data_.right = fragment;
        if (placement == Placement::both) result.data_.right.start = time;
    }
    result.status_ = FragmentSplitStatus::complete;
    return result;
}

// Strict interior/endpoint API retained for existing callers. The permissive
// advance-boundary API above is a distinct operation, not silent normalization.
inline FragmentSplitResult splitStageFragment(const StageFragment &fragment, double time,
                                               SplitOrder order) noexcept {
    if (std::isfinite(time) && time >= fragment.start && time <= fragment.end)
        return splitStageFragmentAtAdvanceBoundary(fragment, time, order);
    FragmentSplitResult result;
    result.status_ = FragmentSplitStatus::invalid_split_time;
    return result;
}

} }
#endif
