// Combines the audited empty-mask single-pending transition with a canonical
// per-source ledger. Independent source key resolution remains an adapter task.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_SINGLE_SOURCE_LEDGER_ADVANCE_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_SINGLE_SOURCE_LEDGER_ADVANCE_HPP

#include "SleepAdvanceDispatch.hpp"
#include "SleepSourceLedger.hpp"
#include <new>
#include <stdexcept>
#include <utility>

namespace watchfix { namespace healthsupport {

enum class SingleLedgerStatus {
    complete,
    unresolved_source_key,
    invalid_configuration,
    single_transition_rejected,
    ledger_update_rejected,
    allocation_failure
};

struct SingleLedgerData {
    SingleAdvanceData advance;
    SourceLedger ledger;
    bool source_contributed = false;
    bool native_source_count_argument = false;
};

class SingleLedgerResult;
SingleLedgerResult advanceSinglePendingWithSourceLedger(const SleepStageDurationReducer &,
    const SourceLedger &, const PendingStageFragment &, std::int64_t, SourceKeyState,
    double, double, bool, std::size_t);

class SingleLedgerResult {
public:
    SingleLedgerStatus status() const noexcept { return status_; }
    SingleAdvanceStatus single_status() const noexcept { return single_status_; }
    SourceLedgerStatus ledger_status() const noexcept { return ledger_status_; }
    bool complete() const noexcept { return status_ == SingleLedgerStatus::complete; }
    const SingleLedgerData *data() const noexcept { return complete() ? &data_ : nullptr; }
private:
    SingleLedgerStatus status_ = SingleLedgerStatus::unresolved_source_key;
    SingleAdvanceStatus single_status_ = SingleAdvanceStatus::invalid_advance;
    SourceLedgerStatus ledger_status_ = SourceLedgerStatus::unresolved_mapping;
    SingleLedgerData data_;
    friend SingleLedgerResult advanceSinglePendingWithSourceLedger(const SleepStageDurationReducer &,
        const SourceLedger &, const PendingStageFragment &, std::int64_t, SourceKeyState,
        double, double, bool, std::size_t);
};

// Exactly one valid pending sample with a key resolved in the SAME mapping
// session as original_ledger. mask_empty is a caller prerequisite, not proof of
// native mask content. No change to total/pending/ledger is published on failure.
inline SingleLedgerResult advanceSinglePendingWithSourceLedger(
    const SleepStageDurationReducer &total, const SourceLedger &original_ledger,
    const PendingStageFragment &pending, std::int64_t canonical_key, SourceKeyState mapping_state,
    double current, double target, bool mask_empty, std::size_t maximum_keys = 10000) {
    SingleLedgerResult result;
    if (mapping_state != SourceKeyState::canonicalized_in_one_mapping_session) return result;
    if (!maximum_keys) { result.status_ = SingleLedgerStatus::invalid_configuration; return result; }
    SingleAdvanceConfiguration configuration;
    configuration.mask_is_empty = mask_empty;
    // The existing transition computes TOTAL and exact pending flags. Source
    // accounting is performed below, not silently skipped.
    configuration.separate_by_source = false;
    auto advanced = advanceSinglePendingTotal(total, pending, current, target, configuration);
    result.single_status_ = advanced.status();
    if (!advanced.complete()) { result.status_ = SingleLedgerStatus::single_transition_rejected; return result; }
    try {
        std::vector<SourceLedgerContribution> contributions;
        if (advanced.data()->contributed) {
            contributions.push_back({advanced.data()->contributed_fragment, canonical_key, !pending.per_source_counted});
        }
        auto updated = accumulateSourceLedger(original_ledger, contributions, mapping_state, maximum_keys, 1);
        result.ledger_status_ = updated.status();
        if (!updated.complete()) { result.status_ = SingleLedgerStatus::ledger_update_rejected; return result; }
        SingleLedgerData candidate;
        candidate.advance = *advanced.data();
        candidate.ledger = updated.data()->ledger;
        candidate.source_contributed = advanced.data()->contributed;
        candidate.native_source_count_argument = advanced.data()->contributed && !pending.per_source_counted;
        result.data_ = std::move(candidate);
        result.status_ = SingleLedgerStatus::complete;
    } catch (const std::bad_alloc &) {
        result.status_ = SingleLedgerStatus::allocation_failure;
    } catch (const std::length_error &) {
        result.status_ = SingleLedgerStatus::allocation_failure;
    }
    return result;
}

} }
#endif
