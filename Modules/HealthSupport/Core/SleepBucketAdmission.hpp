// Transactional raw admission execution with explicit ranking/mapping adapters.
// No calendar guessing, native calls, persistent data writes or runtime hooks.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_BUCKET_ADMISSION_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_BUCKET_ADMISSION_HPP

#include "SleepRawAdmission.hpp"
#include "SleepBucketAdvance.hpp"
#include <algorithm>
#include <functional>
#include <new>
#include <stdexcept>
#include <utility>
#include <vector>

namespace watchfix { namespace healthsupport {

struct BucketLifecycleState {
    CalendarBucketBounds bounds;
    SleepBucketState statistics;
    std::vector<StageFragment> raw_carry;
    // Source registration precedes advancing existing pending. A real ranking
    // adapter receives this complete set, including the new raw sample's source.
    std::vector<std::int64_t> registered_source_ids;
};

struct AdmissionSourceIdentity {
    bool resolved = false;
    std::int64_t ledger_key = 0;
    bool has_bundle_group = false;
    std::int64_t bundle_group = 0;
};

// Mapping is needed AFTER advancing old pending and before creating the new
// ledger. A native adapter must honor that call timing, not prefetch once/day.
using AdmissionIdentity = std::function<AdmissionSourceIdentity(std::int64_t)>;
using RegisteredPendingOrdering = std::function<std::vector<std::size_t>(
    const std::vector<MappedPendingStage> &, const std::vector<std::int64_t> &)>;

enum class BucketAdmissionStatus {
    complete,
    invalid_state,
    invalid_configuration,
    raw_plan_failed,
    unsupported_mask,
    unresolved_order_or_mapping,
    resource_limit,
    advance_failed,
    identity_unresolved,
    ledger_failed,
    allocation_failure,
    adapter_failed
};

class BucketAdmissionResult;
BucketAdmissionResult admitRawStageToBucket(const BucketLifecycleState &, const StageFragment &,
    bool, SplitOrder, const BucketAdvanceConfiguration &, PendingOrderState, SourceKeyState,
    const RegisteredPendingOrdering &, const AdmissionIdentity &, const SourceConsumption *);

class BucketAdmissionResult {
public:
    BucketAdmissionStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == BucketAdmissionStatus::complete; }
    const BucketLifecycleState *state() const noexcept { return complete() ? &state_ : nullptr; }
private:
    BucketAdmissionStatus status_ = BucketAdmissionStatus::invalid_state;
    BucketLifecycleState state_{{0, 0}, {}, {}, {}};
    friend BucketAdmissionResult admitRawStageToBucket(const BucketLifecycleState &, const StageFragment &,
        bool, SplitOrder, const BucketAdvanceConfiguration &, PendingOrderState, SourceKeyState,
        const RegisteredPendingOrdering &, const AdmissionIdentity &, const SourceConsumption *);
};

// Existing pending keys must remain valid during this call or be dynamically
// refreshed by a future adapter. This execution currently covers the stable
// mapping subcase; it is not an excuse to globally enable acceptance without it.
// Transactionality covers OWN returned state only. Callbacks must read only or
// mutate a per-call disposable context, committed together by the adapter after
// success. This function cannot roll back external caches/side effects. The raw
// occurrence is submitted once; equal-valued distinct samples are not deduplicated.
inline BucketAdmissionResult admitRawStageToBucket(
    const BucketLifecycleState &original, const StageFragment &raw, bool advance_before_enqueue,
    SplitOrder end_order, const BucketAdvanceConfiguration &configuration,
    PendingOrderState ordering_state, SourceKeyState key_state,
    const RegisteredPendingOrdering &order, const AdmissionIdentity &identity,
    const SourceConsumption *consumption = nullptr) {
    BucketAdmissionResult result;
    if (!configuration.maximum_pending || !configuration.maximum_keys || !configuration.maximum_steps ||
        !std::isfinite(configuration.merge_granularity) || configuration.merge_granularity <= 0) {
        result.status_ = BucketAdmissionStatus::invalid_configuration; return result;
    }
    if (!configuration.mask_is_empty) { result.status_ = BucketAdmissionStatus::unsupported_mask; return result; }
    if (ordering_state != PendingOrderState::native_equivalent_source_then_start_order ||
        key_state != SourceKeyState::canonicalized_in_one_mapping_session) {
        result.status_ = BucketAdmissionStatus::unresolved_order_or_mapping; return result;
    }
    if (!original.statistics.total.valid() || original.statistics.interval_end != original.bounds.end ||
        !std::isfinite(original.statistics.current)) return result;
    if (original.statistics.pending.size() > configuration.maximum_pending ||
        original.raw_carry.size() > configuration.maximum_pending ||
        original.registered_source_ids.size() > configuration.maximum_keys) {
        result.status_ = BucketAdmissionStatus::resource_limit; return result;
    }
    if (original.statistics.ledger.size() > configuration.maximum_keys) {
        result.status_ = BucketAdmissionStatus::resource_limit; return result;
    }
    for (const auto &item : original.statistics.pending) {
        const auto &fragment = item.pending.fragment;
        if (fragment.category < 1 || fragment.category > 5 || !std::isfinite(fragment.start) ||
            !std::isfinite(fragment.end) || fragment.end <= fragment.start ||
            !std::isfinite(fragment.end - fragment.start) ||
            (configuration.separate_by_source && !consumption && !item.has_ledger_key)) return result;
    }
    for (const auto &fragment : original.raw_carry) {
        if (fragment.category < 1 || fragment.category > 5 || !std::isfinite(fragment.start) ||
            !std::isfinite(fragment.end) || fragment.end <= fragment.start ||
            !std::isfinite(fragment.end - fragment.start)) return result;
    }
    auto plan = planRawStageAdmission(raw, original.bounds, advance_before_enqueue, end_order);
    if (!plan.complete()) { result.status_ = BucketAdmissionStatus::raw_plan_failed; return result; }
    try {
        BucketLifecycleState candidate = original;
        if (plan.data()->has_carry) {
            if (candidate.raw_carry.size() >= configuration.maximum_pending) {
                result.status_ = BucketAdmissionStatus::resource_limit; return result;
            }
            candidate.raw_carry.push_back(plan.data()->carry);
        }
        if (plan.data()->has_pending) {
            const auto &pending = plan.data()->pending;
            auto &sources = candidate.registered_source_ids;
            if (std::find(sources.begin(), sources.end(), pending.fragment.source_id) == sources.end()) {
                if (sources.size() >= configuration.maximum_keys) {
                    result.status_ = BucketAdmissionStatus::resource_limit; return result;
                }
                sources.push_back(pending.fragment.source_id);
            }
            if (plan.data()->advance_existing_before_enqueue) {
                PendingOrdering current_order;
                if (order) current_order = [&](const std::vector<MappedPendingStage> &items) { return order(items, sources); };
                auto advanced = advanceSleepBucket(candidate.statistics, plan.data()->requested_advance_target,
                    configuration, ordering_state, key_state, current_order, consumption);
                if (!advanced.complete()) { result.status_ = BucketAdmissionStatus::advance_failed; return result; }
                candidate.statistics = advanced.data()->state;
            }
            if (candidate.statistics.pending.size() >= configuration.maximum_pending) {
                result.status_ = BucketAdmissionStatus::resource_limit; return result;
            }
            AdmissionSourceIdentity resolved;
            if (configuration.separate_by_source) {
                if (!identity) { result.status_ = BucketAdmissionStatus::identity_unresolved; return result; }
                resolved = identity(pending.fragment.source_id);
                if (!resolved.resolved) { result.status_ = BucketAdmissionStatus::identity_unresolved; return result; }
            }
            candidate.statistics.pending.push_back({pending, resolved.resolved, resolved.ledger_key,
                                                     resolved.has_bundle_group, resolved.bundle_group});
            if (configuration.separate_by_source) {
                auto ensured = ensureSourceLedgerKey(candidate.statistics.ledger, resolved.ledger_key,
                                                     key_state, configuration.maximum_keys);
                if (!ensured.complete()) { result.status_ = BucketAdmissionStatus::ledger_failed; return result; }
                candidate.statistics.ledger = ensured.data()->ledger;
            }
        }
        result.state_ = std::move(candidate);
        result.status_ = BucketAdmissionStatus::complete;
    } catch (const std::bad_alloc &) { result.status_ = BucketAdmissionStatus::allocation_failure; }
    catch (const std::length_error &) { result.status_ = BucketAdmissionStatus::allocation_failure; }
    catch (...) { result.status_ = BucketAdmissionStatus::adapter_failed; }
    return result;
}

} }
#endif
