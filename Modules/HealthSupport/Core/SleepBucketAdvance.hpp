// Bounded bucket advance orchestration. The ordering callback is an audited
// adapter dependency, NOT an implementation or proof of native source sorting.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_BUCKET_ADVANCE_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_BUCKET_ADVANCE_HPP

#include "SleepMultiSourceAdvance.hpp"
#include "SleepSingleSourceLedgerAdvance.hpp"
#include <functional>
#include <new>
#include <stdexcept>
#include <utility>
#include <vector>

namespace watchfix { namespace healthsupport {

struct SleepBucketState {
    SleepStageDurationReducer total;
    SourceLedger ledger;
    std::vector<MappedPendingStage> pending;
    double current = 0;
    double interval_end = 0;
};

struct BucketAdvanceConfiguration {
    double merge_granularity = 30;
    bool mask_is_empty = false;
    bool separate_by_source = true;
    std::size_t maximum_pending = 100000;
    std::size_t maximum_keys = 10000;
    std::size_t maximum_steps = 100000;
};

enum class BucketAdvanceStatus {
    complete,
    invalid_configuration,
    invalid_state,
    unsupported_mask,
    unresolved_order_or_mapping,
    target_plan_failed,
    ordering_rejected,
    event_plan_failed,
    transition_failed,
    iteration_limit,
    no_progress,
    allocation_failure,
    ordering_callback_failed,
    source_lookup_failed
};

// An index permutation of this call's current pending array. It avoids equality
// on fragment data and preserves duplicate item occurrences as distinct inputs.
// Native source-rank then nonstable start sort MUST be supplied by a separately
// reviewed adapter. No guessed stable sort or numeric source priority here.
using PendingOrdering = std::function<std::vector<std::size_t>(const std::vector<MappedPendingStage> &)>;

struct BucketAdvanceData {
    SleepBucketState state;
    double effective_target = 0;
    std::size_t steps = 0;
    std::size_t empty_steps = 0;
    std::size_t single_steps = 0;
    std::size_t multi_steps = 0;
};

class BucketAdvanceResult;
BucketAdvanceResult advanceSleepBucket(const SleepBucketState &, double, const BucketAdvanceConfiguration &,
                                        PendingOrderState, SourceKeyState, const PendingOrdering &, const SourceConsumption *);

class BucketAdvanceResult {
public:
    BucketAdvanceStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == BucketAdvanceStatus::complete; }
    const BucketAdvanceData *data() const noexcept { return complete() ? &data_ : nullptr; }
private:
    BucketAdvanceStatus status_ = BucketAdvanceStatus::invalid_state;
    BucketAdvanceData data_;
    friend BucketAdvanceResult advanceSleepBucket(const SleepBucketState &, double, const BucketAdvanceConfiguration &,
                                                   PendingOrderState, SourceKeyState, const PendingOrdering &, const SourceConsumption *);
};

inline BucketAdvanceResult advanceSleepBucket(
    const SleepBucketState &original, double requested_target, const BucketAdvanceConfiguration &configuration,
    PendingOrderState ordering_state, SourceKeyState mapping_state, const PendingOrdering &order,
    const SourceConsumption *consumption = nullptr) {
    BucketAdvanceResult result;
    if (!configuration.maximum_pending || !configuration.maximum_keys || !configuration.maximum_steps ||
        !std::isfinite(configuration.merge_granularity) || configuration.merge_granularity <= 0) {
        result.status_ = BucketAdvanceStatus::invalid_configuration; return result;
    }
    if (ordering_state != PendingOrderState::native_equivalent_source_then_start_order ||
        mapping_state != SourceKeyState::canonicalized_in_one_mapping_session) {
        result.status_ = BucketAdvanceStatus::unresolved_order_or_mapping; return result;
    }
    if (!configuration.mask_is_empty) { result.status_ = BucketAdvanceStatus::unsupported_mask; return result; }
    if (!original.total.valid() || !std::isfinite(original.current) || !std::isfinite(original.interval_end) ||
        original.pending.size() > configuration.maximum_pending || original.ledger.size() > configuration.maximum_keys) return result;
    for (const auto &item : original.pending) {
        const auto &fragment = item.pending.fragment;
        if (fragment.category < 1 || fragment.category > 5 || !std::isfinite(fragment.start) ||
            !std::isfinite(fragment.end) || fragment.end <= fragment.start ||
            !std::isfinite(fragment.end - fragment.start) ||
            (configuration.separate_by_source && !consumption && !item.has_ledger_key)) return result;
    }
    const auto target = planSourceMergeTarget(original.current, requested_target, original.interval_end,
                                              configuration.merge_granularity);
    if (!target.complete()) { result.status_ = BucketAdvanceStatus::target_plan_failed; return result; }
    try {
        BucketAdvanceData candidate;
        candidate.state = original;
        candidate.effective_target = target.data()->target;
        while (candidate.state.current < candidate.effective_target) {
            if (candidate.steps >= configuration.maximum_steps) {
                result.status_ = BucketAdvanceStatus::iteration_limit; return result;
            }
            const double previous = candidate.state.current;
            if (candidate.state.pending.empty()) {
                // Native empty-pending dispatch advances without creating data.
                if (!std::isfinite(candidate.effective_target - previous)) return result;
                candidate.state.current = candidate.effective_target;
                ++candidate.empty_steps;
            } else if (candidate.state.pending.size() == 1) {
                const auto item = candidate.state.pending.front();
                if (configuration.separate_by_source) {
                    if (consumption) {
                        SingleAdvanceConfiguration single; single.mask_is_empty = true; single.separate_by_source = false;
                        auto step = advanceSinglePendingTotal(candidate.state.total, item.pending, previous,
                                                               candidate.effective_target, single);
                        if (!step.complete()) { result.status_ = BucketAdvanceStatus::transition_failed; return result; }
                        SourceLedger ledger = candidate.state.ledger;
                        if (step.data()->contributed) {
                            // Native first adds TOTAL, then resolves sourceKey;
                            // no bundle-group gate on this single fast path.
                            if (!consumption->key) { result.status_ = BucketAdvanceStatus::source_lookup_failed; return result; }
                            const auto key = consumption->key(item.pending.fragment.source_id);
                            if (!key.resolved) { result.status_ = BucketAdvanceStatus::source_lookup_failed; return result; }
                            auto added = accumulateSourceLedger(ledger,
                                {{step.data()->contributed_fragment, key.key, !item.pending.per_source_counted}},
                                mapping_state, configuration.maximum_keys, 1);
                            if (!added.complete()) { result.status_ = BucketAdvanceStatus::transition_failed; return result; }
                            ledger = added.data()->ledger;
                        }
                        candidate.state.total = step.data()->total; candidate.state.ledger = std::move(ledger);
                        candidate.state.current = step.data()->current; candidate.state.pending.clear();
                        if (step.data()->has_pending) { auto remainder = item; remainder.pending = step.data()->pending; candidate.state.pending.push_back(remainder); }
                    } else {
                        auto step = advanceSinglePendingWithSourceLedger(candidate.state.total, candidate.state.ledger,
                            item.pending, item.ledger_key, mapping_state, previous, candidate.effective_target, true,
                            configuration.maximum_keys);
                        if (!step.complete()) { result.status_ = BucketAdvanceStatus::transition_failed; return result; }
                        candidate.state.total = step.data()->advance.total;
                        candidate.state.ledger = step.data()->ledger;
                        candidate.state.current = step.data()->advance.current;
                        candidate.state.pending.clear();
                        if (step.data()->advance.has_pending) {
                            auto remainder = item; remainder.pending = step.data()->advance.pending;
                            candidate.state.pending.push_back(remainder);
                        }
                    }
                } else {
                    SingleAdvanceConfiguration single;
                    single.mask_is_empty = true; single.separate_by_source = false;
                    auto step = advanceSinglePendingTotal(candidate.state.total, item.pending, previous,
                                                          candidate.effective_target, single);
                    if (!step.complete()) { result.status_ = BucketAdvanceStatus::transition_failed; return result; }
                    candidate.state.total = step.data()->total;
                    candidate.state.current = step.data()->current;
                    candidate.state.pending.clear();
                    if (step.data()->has_pending) { auto remainder = item; remainder.pending = step.data()->pending; candidate.state.pending.push_back(remainder); }
                }
                ++candidate.single_steps;
            } else {
                // Event selection precedes sorting, matching the audited path.
                auto boundary = chooseMultiPendingAdvance(candidate.state.pending, previous,
                                                          candidate.effective_target, configuration.merge_granularity);
                if (!boundary.complete()) { result.status_ = BucketAdvanceStatus::event_plan_failed; return result; }
                if (!order) { result.status_ = BucketAdvanceStatus::ordering_rejected; return result; }
                std::vector<std::size_t> permutation;
                try { permutation = order(candidate.state.pending); }
                catch (const std::bad_alloc &) { throw; }
                catch (const std::length_error &) { throw; }
                catch (...) { result.status_ = BucketAdvanceStatus::ordering_callback_failed; return result; }
                if (permutation.size() != candidate.state.pending.size()) { result.status_ = BucketAdvanceStatus::ordering_rejected; return result; }
                std::vector<bool> seen(permutation.size(), false);
                std::vector<MappedPendingStage> ordered;
                ordered.reserve(permutation.size());
                for (auto index : permutation) {
                    if (index >= seen.size() || seen[index]) { result.status_ = BucketAdvanceStatus::ordering_rejected; return result; }
                    seen[index] = true; ordered.push_back(candidate.state.pending[index]);
                }
                auto step = advanceOrderedMultiPending(candidate.state.total, candidate.state.ledger, ordered,
                    ordering_state, mapping_state, previous, boundary.data()->next, true, configuration.separate_by_source,
                    configuration.maximum_pending, configuration.maximum_keys, consumption);
                if (!step.complete()) {
                    result.status_ = step.status() == MultiAdvanceStatus::source_lookup_failed ?
                        BucketAdvanceStatus::source_lookup_failed : BucketAdvanceStatus::transition_failed;
                    return result;
                }
                candidate.state.total = step.data()->total;
                candidate.state.ledger = step.data()->ledger;
                candidate.state.pending = step.data()->pending;
                candidate.state.current = step.data()->current;
                ++candidate.multi_steps;
            }
            if (!(candidate.state.current > previous)) { result.status_ = BucketAdvanceStatus::no_progress; return result; }
            ++candidate.steps;
        }
        result.data_ = std::move(candidate);
        result.status_ = BucketAdvanceStatus::complete;
    } catch (const std::bad_alloc &) { result.status_ = BucketAdvanceStatus::allocation_failure; }
    catch (const std::length_error &) { result.status_ = BucketAdvanceStatus::allocation_failure; }
    catch (...) { result.status_ = BucketAdvanceStatus::source_lookup_failed; }
    return result;
}

} }
#endif
