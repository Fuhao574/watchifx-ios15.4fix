// Sequential calendar-bucket rollover only. Moves independently captured RAW
// carry, not old pending/history/current/ledger/mapping. No calendar arithmetic.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_BUCKET_ROLLOVER_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_BUCKET_ROLLOVER_HPP

#include "SleepBucketAdmission.hpp"
#include <new>
#include <stdexcept>
#include <utility>

namespace watchfix { namespace healthsupport {

enum class BucketRolloverStatus {
    complete,
    invalid_calendar_bounds,
    invalid_state,
    resource_limit,
    previous_advance_failed,
    carry_admission_failed,
    allocation_failure
};

struct BucketRolloverData {
    CalendarBucketBounds previous_bounds{0, 0};
    SleepBucketState finished_previous;
    BucketLifecycleState next{{0, 0}, {}, {}, {}};
    std::size_t replayed_raw_fragments = 0;
};

class BucketRolloverResult;
BucketRolloverResult rolloverSleepBucket(const BucketLifecycleState &, CalendarBucketBounds,
    SplitOrder, const BucketAdvanceConfiguration &, PendingOrderState, SourceKeyState,
    const RegisteredPendingOrdering &, const AdmissionIdentity &, const SourceConsumption *, const SourceConsumption *, const RegisteredPendingOrdering *, bool);

class BucketRolloverResult {
public:
    BucketRolloverStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == BucketRolloverStatus::complete; }
    const BucketRolloverData *data() const noexcept { return complete() ? &data_ : nullptr; }
private:
    BucketRolloverStatus status_ = BucketRolloverStatus::invalid_state;
    BucketRolloverData data_;
    friend BucketRolloverResult rolloverSleepBucket(const BucketLifecycleState &, CalendarBucketBounds,
        SplitOrder, const BucketAdvanceConfiguration &, PendingOrderState, SourceKeyState,
        const RegisteredPendingOrdering &, const AdmissionIdentity &, const SourceConsumption *, const SourceConsumption *, const RegisteredPendingOrdering *, bool);
};

// next_bounds is obtained from collection index+1, not derived by adding60 or
// 86400. Default is contiguous sequential rollover. The explicit raw-routing
// option permits a forward gap ONLY when independent raw carry is empty.
// new_bucket_identity MUST use a fresh bucket mapping; never capture/reuse the
// previous map. The callback is outside owned-state rollback: the adapter must
// stage its own lookup/cache changes until the complete result is selected.
inline BucketRolloverResult rolloverSleepBucket(
    const BucketLifecycleState &original, CalendarBucketBounds next_bounds, SplitOrder end_order,
    const BucketAdvanceConfiguration &configuration, PendingOrderState ordering_state,
    SourceKeyState key_state, const RegisteredPendingOrdering &order,
    const AdmissionIdentity &new_bucket_identity, const SourceConsumption *previous_consumption = nullptr,
    const SourceConsumption *new_bucket_consumption = nullptr,
    const RegisteredPendingOrdering *new_bucket_order = nullptr, bool allow_empty_carry_jump = false) {
    BucketRolloverResult result;
    if (!std::isfinite(original.bounds.start) || !std::isfinite(original.bounds.end) ||
        original.bounds.end <= original.bounds.start || !std::isfinite(original.bounds.end - original.bounds.start) ||
        !std::isfinite(next_bounds.start) || !std::isfinite(next_bounds.end) ||
        next_bounds.end <= next_bounds.start || !std::isfinite(next_bounds.end - next_bounds.start) ||
        (next_bounds.start != original.bounds.end && !(allow_empty_carry_jump && original.raw_carry.empty() &&
                                                      next_bounds.start > original.bounds.end))) {
        result.status_ = BucketRolloverStatus::invalid_calendar_bounds; return result;
    }
    if (original.statistics.interval_end != original.bounds.end || !original.statistics.total.valid()) return result;
    if (!configuration.maximum_pending || original.raw_carry.size() > configuration.maximum_pending ||
        original.registered_source_ids.size() > configuration.maximum_keys) {
        result.status_ = BucketRolloverStatus::resource_limit; return result;
    }
    for (const auto &raw : original.raw_carry) {
        if (raw.category < 1 || raw.category > 5 || !std::isfinite(raw.start) || !std::isfinite(raw.end) ||
            raw.end <= raw.start || !std::isfinite(raw.end - raw.start)) return result;
    }
    if (end_order != SplitOrder::numeric_zero && end_order != SplitOrder::numeric_one) return result;
    try {
        // Snapshot carry BEFORE old advance. Finalized old current/pending is
        // never used to recover, clamp or regenerate the next raw carry.
        const auto raw_carry = original.raw_carry;
        PendingOrdering previous_order;
        if (order) previous_order = [&](const std::vector<MappedPendingStage> &pending) {
            return order(pending, original.registered_source_ids);
        };
        auto completed = advanceSleepBucket(original.statistics, original.bounds.end, configuration,
                                             ordering_state, key_state, previous_order, previous_consumption);
        if (!completed.complete()) { result.status_ = BucketRolloverStatus::previous_advance_failed; return result; }
        BucketRolloverData candidate;
        candidate.previous_bounds = original.bounds;
        candidate.finished_previous = completed.data()->state;
        candidate.next.bounds = next_bounds;
        candidate.next.statistics.current = next_bounds.start;
        candidate.next.statistics.interval_end = next_bounds.end;
        // Default new reducers/maps/registered-source list/pending. Config and
        // provider behavior are supplied separately, not copied from old state.
        for (const auto &raw : raw_carry) {
            auto replay = admitRawStageToBucket(candidate.next, raw, true, end_order, configuration,
                    ordering_state, key_state, new_bucket_order ? *new_bucket_order : order,
                    new_bucket_identity, new_bucket_consumption);
            if (!replay.complete()) { result.status_ = BucketRolloverStatus::carry_admission_failed; return result; }
            candidate.next = *replay.state();
            ++candidate.replayed_raw_fragments;
        }
        result.data_ = std::move(candidate);
        result.status_ = BucketRolloverStatus::complete;
    } catch (const std::bad_alloc &) { result.status_ = BucketRolloverStatus::allocation_failure; }
    catch (const std::length_error &) { result.status_ = BucketRolloverStatus::allocation_failure; }
    return result;
}

} }
#endif
