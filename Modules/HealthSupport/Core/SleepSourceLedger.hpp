// Per-statistics-bucket source reducers with adapter-supplied canonical keys.
// Native source->bundle canonicalization belongs to the adapter, not this map.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_SOURCE_LEDGER_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_SOURCE_LEDGER_HPP

#include "SleepStageDurationReducer.hpp"
#include "SleepStageFragments.hpp"
#include <cstddef>
#include <cstdint>
#include <map>
#include <new>
#include <stdexcept>
#include <utility>
#include <vector>

namespace watchfix { namespace healthsupport {

// Canonical key from one bucket's source-mapping history. Native uses a
// representative sourceID (or raw ID without provider), not bundle hash or rank.
// Consumers treat it as opaque; distinct raw sourceIDs can share a key.
struct SourceLedgerContribution {
    StageFragment fragment;
    std::int64_t canonical_key;
    bool native_count_argument;
};

enum class SourceLedgerStatus {
    complete,
    unresolved_mapping,
    invalid_configuration,
    contribution_limit,
    key_limit,
    invalid_fragment,
    invalid_accumulation,
    allocation_failure
};

enum class SourceKeyState { unresolved, canonicalized_in_one_mapping_session };

class SourceLedger;
class SourceLedgerResult;
SourceLedgerResult accumulateSourceLedger(const SourceLedger &,
    const std::vector<SourceLedgerContribution> &, SourceKeyState, std::size_t, std::size_t);
SourceLedgerResult ensureSourceLedgerKey(const SourceLedger &, std::int64_t, SourceKeyState, std::size_t);

class SourceLedger {
public:
    const SleepStageDurationReducer *find(std::int64_t key) const noexcept {
        const auto found = reducers_.find(key);
        return found == reducers_.end() ? nullptr : &found->second;
    }
    std::size_t size() const noexcept { return reducers_.size(); }
private:
    std::map<std::int64_t, SleepStageDurationReducer> reducers_;
    friend SourceLedgerResult accumulateSourceLedger(const SourceLedger &,
        const std::vector<SourceLedgerContribution> &, SourceKeyState, std::size_t, std::size_t);
    friend SourceLedgerResult ensureSourceLedgerKey(const SourceLedger &, std::int64_t, SourceKeyState, std::size_t);
};

struct SourceLedgerData {
    SourceLedger ledger;
    std::size_t contributed_fragments = 0;
    // Report how often native's count=true would be supplied; this is not an
    // implementation of archived native counters. count=false still adds time.
    std::size_t native_count_true_arguments = 0;
};

class SourceLedgerResult {
public:
    SourceLedgerStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == SourceLedgerStatus::complete; }
    const SourceLedgerData *data() const noexcept { return complete() ? &data_ : nullptr; }
private:
    SourceLedgerStatus status_ = SourceLedgerStatus::unresolved_mapping;
    SourceLedgerData data_;
    friend SourceLedgerResult accumulateSourceLedger(const SourceLedger &,
        const std::vector<SourceLedgerContribution> &, SourceKeyState, std::size_t, std::size_t);
    friend SourceLedgerResult ensureSourceLedgerKey(const SourceLedger &, std::int64_t, SourceKeyState, std::size_t);
};

// Native admission creates an EMPTY ledger before any addSample. Do not fake
// this by adding a zero-duration category, which would consume tie sequence.
inline SourceLedgerResult ensureSourceLedgerKey(const SourceLedger &original, std::int64_t key,
                                                SourceKeyState state, std::size_t maximum_keys = 10000) {
    SourceLedgerResult result;
    if (state != SourceKeyState::canonicalized_in_one_mapping_session) return result;
    if (!maximum_keys) { result.status_ = SourceLedgerStatus::invalid_configuration; return result; }
    if (original.size() > maximum_keys || (!original.find(key) && original.size() >= maximum_keys)) {
        result.status_ = SourceLedgerStatus::key_limit; return result;
    }
    try {
        result.data_.ledger = original;
        result.data_.ledger.reducers_.emplace(key, SleepStageDurationReducer());
        result.status_ = SourceLedgerStatus::complete;
    } catch (const std::bad_alloc &) { result.status_ = SourceLedgerStatus::allocation_failure; }
    catch (const std::length_error &) { result.status_ = SourceLedgerStatus::allocation_failure; }
    return result;
}

// Input order preserves each ledger's first-seen stage tie sequence. Do not sort
// by key/category. Source ledger records every provided effective contribution,
// independently of whether that source contributed to strategy0 TOTAL.
// All original and new keys MUST come from the SAME bucket mapping history.
// Native nil->nonnull/provider loss may change a raw source's later key WITHOUT
// migrating/rebuilding its old ledger. Unrelated sessions or arbitrary token
// renumbering must not be mixed. SourceKeyState does not enforce that provenance.
inline SourceLedgerResult accumulateSourceLedger(
    const SourceLedger &original, const std::vector<SourceLedgerContribution> &contributions,
    SourceKeyState mapping_state, std::size_t maximum_keys = 10000,
    std::size_t maximum_contributions = 100000) {
    SourceLedgerResult result;
    if (mapping_state != SourceKeyState::canonicalized_in_one_mapping_session) return result;
    if (!maximum_keys || !maximum_contributions) {
        result.status_ = SourceLedgerStatus::invalid_configuration; return result;
    }
    if (contributions.size() > maximum_contributions) {
        result.status_ = SourceLedgerStatus::contribution_limit; return result;
    }
    if (original.size() > maximum_keys) { result.status_ = SourceLedgerStatus::key_limit; return result; }
    for (const auto &input : contributions) {
        const auto &fragment = input.fragment;
        if (fragment.category < 1 || fragment.category > 5 ||
            !std::isfinite(fragment.start) || !std::isfinite(fragment.end) ||
            fragment.end <= fragment.start || !std::isfinite(fragment.end - fragment.start)) {
            result.status_ = SourceLedgerStatus::invalid_fragment; return result;
        }
    }
    try {
        SourceLedgerData candidate;
        candidate.ledger = original;
        for (const auto &input : contributions) {
            auto found = candidate.ledger.reducers_.find(input.canonical_key);
            if (found == candidate.ledger.reducers_.end()) {
                if (candidate.ledger.size() >= maximum_keys) {
                    result.status_ = SourceLedgerStatus::key_limit; return result;
                }
                found = candidate.ledger.reducers_.emplace(input.canonical_key, SleepStageDurationReducer()).first;
            }
            if (!found->second.add(input.fragment.category, input.fragment.start, input.fragment.end)) {
                result.status_ = SourceLedgerStatus::invalid_accumulation; return result;
            }
            ++candidate.contributed_fragments;
            if (input.native_count_argument) ++candidate.native_count_true_arguments;
        }
        result.data_ = std::move(candidate);
        result.status_ = SourceLedgerStatus::complete;
    } catch (const std::bad_alloc &) {
        result.status_ = SourceLedgerStatus::allocation_failure;
    } catch (const std::length_error &) {
        result.status_ = SourceLedgerStatus::allocation_failure;
    }
    return result;
}

} }
#endif
