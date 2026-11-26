// One MULTI-pending transition. Native-equivalent sorting and source-key mapping
// are explicit upstream prerequisites; this file never substitutes a stable sort.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_MULTI_SOURCE_ADVANCE_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_MULTI_SOURCE_ADVANCE_HPP

#include "SleepAdvanceDispatch.hpp"
#include "SleepSourceMergeAdvance.hpp"
#include "SleepSourceLedger.hpp"
#include <map>
#include <functional>
#include <new>
#include <stdexcept>
#include <utility>
#include <vector>

namespace watchfix { namespace healthsupport {

struct MappedPendingStage {
    PendingStageFragment pending;
    bool has_ledger_key;
    std::int64_t ledger_key;
    // Multi per-source gating requires a NONNIL bundle group. A canonical
    // ledger key may still exist for nil bundle/no provider (single path uses
    // it), so key availability alone must not enable multi ledger contribution.
    bool has_bundle_group;
    std::int64_t bundle_group;
};

// Native consumption points, not one-time pre-mapping at admission. Callbacks
// operate on a private staged mapping context; external effects cannot roll back.
// Bundle lookup must NOT pick/change a ledger representative on its own.
struct ConsumptionBundle {
    bool resolved = false;
    bool nonnull = false;
    std::int64_t group = 0;
};
struct ConsumptionKey { bool resolved = false; std::int64_t key = 0; };
struct SourceConsumption {
    std::function<ConsumptionBundle(std::int64_t)> bundle;
    std::function<ConsumptionKey(std::int64_t)> key;
};

enum class MultiAdvanceStatus {
    complete,
    unresolved_order_or_mapping,
    invalid_configuration,
    invalid_state,
    pending_limit,
    invalid_fragment,
    invalid_advance,
    unsupported_nonempty_mask,
    split_failed,
    total_failed,
    ledger_failed,
    source_lookup_failed,
    allocation_failure
};

enum class PendingOrderState { unresolved, native_equivalent_source_then_start_order };

struct MultiAdvanceData {
    SleepStageDurationReducer total;
    SourceLedger ledger;
    std::vector<MappedPendingStage> pending;
    double current = 0;
    bool has_total_source = false;
    std::int64_t total_source_id = 0;
    std::size_t total_contributions = 0;
    std::size_t source_contributions = 0;
};

class MultiAdvanceResult;
MultiAdvanceResult advanceOrderedMultiPending(const SleepStageDurationReducer &, const SourceLedger &,
    const std::vector<MappedPendingStage> &, PendingOrderState, SourceKeyState,
    double, double, bool, bool, std::size_t, std::size_t, const SourceConsumption *);

class MultiAdvanceResult {
public:
    MultiAdvanceStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == MultiAdvanceStatus::complete; }
    const MultiAdvanceData *data() const noexcept { return complete() ? &data_ : nullptr; }
private:
    MultiAdvanceStatus status_ = MultiAdvanceStatus::unresolved_order_or_mapping;
    MultiAdvanceData data_;
    friend MultiAdvanceResult advanceOrderedMultiPending(const SleepStageDurationReducer &, const SourceLedger &,
        const std::vector<MappedPendingStage> &, PendingOrderState, SourceKeyState,
        double, double, bool, bool, std::size_t, std::size_t, const SourceConsumption *);
};

// boundary is the already chosen event/grid result, potentially beyond target or
// individual sample endpoints. Source strategy is0 only. All inputs raw-valid,
// finite and positive. No mask implementation is presumed when mask_empty=false.
// Source-key NONE is distinct from token0; every call uses one stable mapping.
inline MultiAdvanceResult advanceOrderedMultiPending(
    const SleepStageDurationReducer &original_total, const SourceLedger &original_ledger,
    const std::vector<MappedPendingStage> &ordered, PendingOrderState order_state, SourceKeyState key_state,
    double current, double boundary, bool mask_empty, bool separate_by_source,
    std::size_t maximum_pending = 100000, std::size_t maximum_keys = 10000,
    const SourceConsumption *consumption = nullptr) {
    MultiAdvanceResult result;
    if (order_state != PendingOrderState::native_equivalent_source_then_start_order ||
        key_state != SourceKeyState::canonicalized_in_one_mapping_session) return result;
    if (!maximum_pending || !maximum_keys) { result.status_ = MultiAdvanceStatus::invalid_configuration; return result; }
    if (!original_total.valid() || ordered.size() < 2) { result.status_ = MultiAdvanceStatus::invalid_state; return result; }
    if (ordered.size() > maximum_pending) { result.status_ = MultiAdvanceStatus::pending_limit; return result; }
    if (!std::isfinite(current) || !std::isfinite(boundary) || boundary <= current ||
        !std::isfinite(boundary - current)) { result.status_ = MultiAdvanceStatus::invalid_advance; return result; }
    if (!mask_empty) { result.status_ = MultiAdvanceStatus::unsupported_nonempty_mask; return result; }
    for (const auto &item : ordered) {
        const auto &fragment = item.pending.fragment;
        if (fragment.category < 1 || fragment.category > 5 || !std::isfinite(fragment.start) ||
            !std::isfinite(fragment.end) || fragment.end <= fragment.start ||
            !std::isfinite(fragment.end - fragment.start)) {
            result.status_ = MultiAdvanceStatus::invalid_fragment; return result;
        }
    }
    try {
        MultiAdvanceData candidate;
        candidate.total = original_total;
        candidate.current = boundary;
        std::vector<SourceLedgerContribution> source_inputs;
        std::map<std::int64_t, std::int64_t> representatives;
        candidate.pending.reserve(ordered.size());
        for (const auto &item : ordered) {
            auto split = splitStageFragmentAtAdvanceBoundary(item.pending.fragment, boundary, SplitOrder::numeric_zero);
            if (!split.complete()) { result.status_ = MultiAdvanceStatus::split_failed; return result; }
            if (!split.data()->left_valid) {
                // Native preserves the original WHOLE pending item, not a
                // temporary invalid-side struct, including all H/S/A flags.
                candidate.pending.push_back(item);
                continue;
            }
            const auto &left = split.data()->left;
            MappedPendingStage next = item;
            if (!candidate.has_total_source || left.source_id == candidate.total_source_id) {
                if (!candidate.total.add(left.category, left.start, left.end)) {
                    result.status_ = MultiAdvanceStatus::total_failed; return result;
                }
                next.pending.total_counted = true;
                ++candidate.total_contributions;
                if (!candidate.has_total_source) candidate.total_source_id = left.source_id;
            }
            ConsumptionBundle bundle;
            if (separate_by_source) {
                if (consumption) {
                    if (!consumption->bundle) {
                        result.status_ = MultiAdvanceStatus::source_lookup_failed; return result;
                    }
                    bundle = consumption->bundle(left.source_id);
                    if (!bundle.resolved) { result.status_ = MultiAdvanceStatus::source_lookup_failed; return result; }
                } else { bundle.resolved = true; bundle.nonnull = item.has_bundle_group && item.has_ledger_key; bundle.group = item.bundle_group; }
            }
            if (separate_by_source && bundle.nonnull) {
                auto representative = representatives.find(bundle.group);
                if (representative == representatives.end())
                    representative = representatives.emplace(bundle.group, left.source_id).first;
                if (representative->second == left.source_id) {
                    ConsumptionKey key;
                    if (consumption) {
                        if (!consumption->key) { result.status_ = MultiAdvanceStatus::source_lookup_failed; return result; }
                        key = consumption->key(left.source_id);
                    }
                    else { key.resolved = item.has_ledger_key; key.key = item.ledger_key; }
                    if (!key.resolved) { result.status_ = MultiAdvanceStatus::source_lookup_failed; return result; }
                    source_inputs.push_back({left, key.key, !item.pending.per_source_counted});
                    next.pending.per_source_counted = true;
                    ++candidate.source_contributions;
                }
            }
            candidate.has_total_source = true;
            // Multi path leaves H unchanged (unlike the single-pending path).
            if (split.data()->right_valid) {
                next.pending.fragment = split.data()->right;
                candidate.pending.push_back(next);
            }
        }
        auto ledger = accumulateSourceLedger(original_ledger, source_inputs, key_state, maximum_keys, maximum_pending);
        if (!ledger.complete()) { result.status_ = MultiAdvanceStatus::ledger_failed; return result; }
        candidate.ledger = ledger.data()->ledger;
        result.data_ = std::move(candidate);
        result.status_ = MultiAdvanceStatus::complete;
    } catch (const std::bad_alloc &) {
        result.status_ = MultiAdvanceStatus::allocation_failure;
    } catch (const std::length_error &) {
        result.status_ = MultiAdvanceStatus::allocation_failure;
    } catch (...) { result.status_ = MultiAdvanceStatus::source_lookup_failed; }
    return result;
}

// Event selection is independent of source ordering. Native scans every pending
// start/end, taking only boundaries strictly after current, initially target.
// This finite helper does not normalize malformed state or enforce a day end.
inline SourceAdvanceResult chooseMultiPendingAdvance(const std::vector<MappedPendingStage> &pending,
                                                       double current, double target, double granularity) noexcept {
    if (!std::isfinite(current) || !std::isfinite(target) || target <= current ||
        !std::isfinite(granularity) || granularity <= 0 || pending.size() < 2)
        return nextMultiSampleSourceMergeTime(current, current, granularity); // explicit invalid result
    double event = target;
    for (const auto &item : pending) {
        const auto &fragment = item.pending.fragment;
        if (!std::isfinite(fragment.start) || !std::isfinite(fragment.end) || fragment.end <= fragment.start)
            return nextMultiSampleSourceMergeTime(current, current, granularity);
        if (fragment.start > current && fragment.start < event) event = fragment.start;
        if (fragment.end > current && fragment.end < event) event = fragment.end;
    }
    return nextMultiSampleSourceMergeTime(current, event, granularity);
}

} }
#endif
