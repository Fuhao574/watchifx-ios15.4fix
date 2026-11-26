// One audited strategy0 contribution step AFTER caller source/time ordering,
// validity/mask handling and interval splitting. This is NOT an ordering engine.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_SOURCE_SLICE_ACCUMULATOR_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_SOURCE_SLICE_ACCUMULATOR_HPP

#include "SleepStageDurationReducer.hpp"
#include "SleepStageFragments.hpp"
#include <cmath>
#include <cstddef>
#include <vector>

namespace watchfix { namespace healthsupport {

enum class SliceInputState { unresolved_fragments, ordered_valid_split_fragments };
enum class SourceSliceStatus {
    complete,
    unresolved_ordering,
    invalid_bucket_state,
    invalid_slice,
    fragment_limit,
    invalid_fragment,
    fragment_outside_slice,
    invalid_accumulation
};

struct SourceSliceData {
    // Transactional copy of the caller bucket. No partial updates on failure.
    SleepStageDurationReducer total;
    bool has_contributing_source = false;
    // No sentinel source ID; read ONLY when has_contributing_source is true.
    std::int64_t selected_source_id = 0;
    // Counts refer to this invocation's fragments, not native counters, distinct
    // sources, durations or bucket-stage validity. maximum_fragments0 rejects.
    std::size_t contributing_fragments = 0;
    std::size_t other_source_fragments = 0;
};

class SourceSliceResult;
SourceSliceResult accumulateOrderedSourceSlice(const SleepStageDurationReducer &,
    const std::vector<StageFragment> &, double, double, SliceInputState, std::size_t) noexcept;

class SourceSliceResult {
public:
    SourceSliceStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == SourceSliceStatus::complete; }
    const SourceSliceData *data() const noexcept { return complete() ? &data_ : nullptr; }
private:
    SourceSliceStatus status_ = SourceSliceStatus::unresolved_ordering;
    SourceSliceData data_;
    friend SourceSliceResult accumulateOrderedSourceSlice(const SleepStageDurationReducer &,
        const std::vector<StageFragment> &, double, double, SliceInputState, std::size_t) noexcept;
};

// Preserves the supplied traversal order; deliberately never sorts by source ID,
// provider rank, category or time. Upstream must establish the actual native
// ordering, including equal-start behavior. The enum doesn't prove that work.
// One invocation must correspond to ONE native advance; arbitrary re-slicing,
// duplicate slices or changing bucket boundaries would change source selection.
inline SourceSliceResult accumulateOrderedSourceSlice(
    const SleepStageDurationReducer &bucket,
    const std::vector<StageFragment> &fragments,
    double slice_start, double slice_end,
    SliceInputState input_state,
    std::size_t maximum_fragments = 100000) noexcept {
    SourceSliceResult result;
    if (input_state != SliceInputState::ordered_valid_split_fragments) return result;
    if (!bucket.valid()) { result.status_ = SourceSliceStatus::invalid_bucket_state; return result; }
    if (!std::isfinite(slice_start) || !std::isfinite(slice_end) || slice_end <= slice_start ||
        !std::isfinite(slice_end - slice_start)) {
        result.status_ = SourceSliceStatus::invalid_slice;
        return result;
    }
    if (!maximum_fragments || fragments.size() > maximum_fragments) {
        result.status_ = SourceSliceStatus::fragment_limit;
        return result;
    }
    for (const auto &fragment : fragments) {
        if (fragment.category < 1 || fragment.category > 5 ||
            !std::isfinite(fragment.start) || !std::isfinite(fragment.end) ||
            fragment.end <= fragment.start || !std::isfinite(fragment.end - fragment.start)) {
            result.status_ = SourceSliceStatus::invalid_fragment;
            return result;
        }
        if (fragment.start < slice_start || fragment.end > slice_end) {
            result.status_ = SourceSliceStatus::fragment_outside_slice;
            return result;
        }
    }
    SourceSliceData candidate;
    candidate.total = bucket;
    for (const auto &fragment : fragments) {
        if (!candidate.has_contributing_source) {
            candidate.selected_source_id = fragment.source_id;
            candidate.has_contributing_source = true;
        }
        if (fragment.source_id != candidate.selected_source_id) {
            // Not globally discarded: a future SeparateBySource ledger may
            // retain it. This class implements TOTAL strategy0 contribution only.
            ++candidate.other_source_fragments;
            continue;
        }
        if (!candidate.total.add(fragment.category, fragment.start, fragment.end)) {
            result.status_ = SourceSliceStatus::invalid_accumulation;
            return result;
        }
        ++candidate.contributing_fragments;
    }
    result.data_ = candidate;
    result.status_ = SourceSliceStatus::complete;
    return result;
}

} }
#endif
