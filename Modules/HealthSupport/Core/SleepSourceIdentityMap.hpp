// Bucket-local native source-key semantics. Only independently written value
// containers and adapter-supplied lookup outcomes; no HealthKit/source queries.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_SOURCE_IDENTITY_MAP_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_SOURCE_IDENTITY_MAP_HPP

#include <cstddef>
#include <cstdint>
#include <map>
#include <new>
#include <stdexcept>
#include <string>
#include <utility>

namespace watchfix { namespace healthsupport {

enum class BundleLookupKind { not_observed, nonnull_bundle, nil_bundle };
struct SourceBundleLookup {
    BundleLookupKind kind = BundleLookupKind::not_observed;
    std::string bundle;
    SourceBundleLookup() = default;
    SourceBundleLookup(BundleLookupKind state, std::string value) : kind(state), bundle(std::move(value)) {}
};

enum class SourceIdentityStatus {
    complete,
    lookup_required,
    invalid_lookup_state,
    invalid_configuration,
    cache_limit,
    allocation_failure
};

class SleepSourceIdentityMap;
class SourceIdentityResult;
class SourceBundleObservation;
SourceBundleObservation observeSourceBundle(const SleepSourceIdentityMap &, std::int64_t,
    bool, const SourceBundleLookup &, std::size_t);
SourceIdentityResult resolveSourceIdentity(const SleepSourceIdentityMap &, std::int64_t,
    bool, const SourceBundleLookup &, std::size_t, std::size_t);
SourceIdentityResult resolveSourceKeyFromObservedBundle(const SleepSourceIdentityMap &, std::int64_t,
    const SourceBundleLookup &, std::size_t);

// One bucket only. Native also has an override table that sourceKey reads, but
// its writers have not been audited. This class models the audited MISS path:
// callers must separately establish no externally-installed key override exists.
class SleepSourceIdentityMap {
public:
    bool needs_bundle_lookup(std::int64_t source, bool provider_present) const noexcept {
        return provider_present && nonnull_bundles_.find(source) == nonnull_bundles_.end();
    }
    std::size_t cached_sources() const noexcept { return nonnull_bundles_.size(); }
    std::size_t nonnull_bundle_groups() const noexcept { return representatives_.size(); }
private:
    std::map<std::int64_t, std::string> nonnull_bundles_;
    std::map<std::string, std::int64_t> representatives_;
    bool has_nil_representative_ = false;
    std::int64_t nil_representative_ = 0;
    friend SourceIdentityResult resolveSourceIdentity(const SleepSourceIdentityMap &, std::int64_t,
        bool, const SourceBundleLookup &, std::size_t, std::size_t);
    friend SourceIdentityResult resolveSourceKeyFromObservedBundle(const SleepSourceIdentityMap &, std::int64_t,
        const SourceBundleLookup &, std::size_t);
    friend SourceBundleObservation observeSourceBundle(const SleepSourceIdentityMap &, std::int64_t,
        bool, const SourceBundleLookup &, std::size_t);
};

// Native bundleForSourceID can cache a nonnil bundle WITHOUT selecting a
// sourceKey reverse representative. Multi calls this before its per-group gate.
// Calling resolveSourceIdentity merely to ask for bundle would select keys too
// early and change subsequent first-representative behavior.
class SourceBundleObservation {
public:
    SourceIdentityStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == SourceIdentityStatus::complete; }
    const SleepSourceIdentityMap *mapping() const noexcept { return complete() ? &mapping_ : nullptr; }
    const std::string *bundle() const noexcept { return complete() && nonnull_ ? &bundle_ : nullptr; }
private:
    SourceIdentityStatus status_ = SourceIdentityStatus::lookup_required;
    SleepSourceIdentityMap mapping_;
    bool nonnull_ = false;
    std::string bundle_;
    friend SourceBundleObservation observeSourceBundle(const SleepSourceIdentityMap &, std::int64_t,
        bool, const SourceBundleLookup &, std::size_t);
};

inline SourceBundleObservation observeSourceBundle(const SleepSourceIdentityMap &original, std::int64_t source,
    bool provider_present, const SourceBundleLookup &lookup, std::size_t maximum_cached_sources = 10000) {
    SourceBundleObservation result;
    if (!maximum_cached_sources) { result.status_ = SourceIdentityStatus::invalid_configuration; return result; }
    if (original.cached_sources() > maximum_cached_sources) { result.status_ = SourceIdentityStatus::cache_limit; return result; }
    try {
        result.mapping_ = original;
        if (provider_present) {
            auto cached = result.mapping_.nonnull_bundles_.find(source);
            if (cached == result.mapping_.nonnull_bundles_.end()) {
                if (lookup.kind == BundleLookupKind::not_observed) return result;
                if (lookup.kind == BundleLookupKind::nonnull_bundle) {
                    if (original.cached_sources() >= maximum_cached_sources) {
                        result.status_ = SourceIdentityStatus::cache_limit; return result;
                    }
                    cached = result.mapping_.nonnull_bundles_.emplace(source, lookup.bundle).first;
                } else if (lookup.kind != BundleLookupKind::nil_bundle) {
                    result.status_ = SourceIdentityStatus::invalid_lookup_state; return result;
                }
            }
            if (cached != result.mapping_.nonnull_bundles_.end()) {
                result.nonnull_ = true; result.bundle_ = cached->second;
            }
        }
        result.status_ = SourceIdentityStatus::complete;
    } catch (const std::bad_alloc &) { result.status_ = SourceIdentityStatus::allocation_failure; }
    catch (const std::length_error &) { result.status_ = SourceIdentityStatus::allocation_failure; }
    return result;
}

struct SourceIdentityData {
    SleepSourceIdentityMap mapping;
    // Native representative sourceID, NOT a new sequence assigned from source
    // rank or a hash of the bundle string. It can change after a nil->nonnull
    // lookup or provider loss; prior ledger state is never migrated implicitly.
    std::int64_t ledger_key = 0;
    bool has_bundle_group = false;
    std::int64_t bundle_group = 0;
};

class SourceIdentityResult {
public:
    SourceIdentityStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == SourceIdentityStatus::complete; }
    const SourceIdentityData *data() const noexcept { return complete() ? &data_ : nullptr; }
private:
    SourceIdentityStatus status_ = SourceIdentityStatus::lookup_required;
    SourceIdentityData data_;
    friend SourceIdentityResult resolveSourceIdentity(const SleepSourceIdentityMap &, std::int64_t,
        bool, const SourceBundleLookup &, std::size_t, std::size_t);
    friend SourceIdentityResult resolveSourceKeyFromObservedBundle(const SleepSourceIdentityMap &, std::int64_t,
        const SourceBundleLookup &, std::size_t);
};

// Outer sourceKey already observed a present provider; inner bundle helper has
// independently read its weak provider and returned this exact nil/non-nil
// result. Do NOT reconsult raw-source cache here: inner provider may have vanished
// even when that source has a cached bundle. Does not create/cache bundle data.
inline SourceIdentityResult resolveSourceKeyFromObservedBundle(
    const SleepSourceIdentityMap &original, std::int64_t source,
    const SourceBundleLookup &observed, std::size_t maximum_bundle_groups = 10000) {
    SourceIdentityResult result;
    if (!maximum_bundle_groups) { result.status_ = SourceIdentityStatus::invalid_configuration; return result; }
    if (original.nonnull_bundle_groups() > maximum_bundle_groups) { result.status_ = SourceIdentityStatus::cache_limit; return result; }
    if (observed.kind != BundleLookupKind::nonnull_bundle && observed.kind != BundleLookupKind::nil_bundle) return result;
    try {
        SourceIdentityData candidate; candidate.mapping = original;
        if (observed.kind == BundleLookupKind::nonnull_bundle) {
            auto representative = candidate.mapping.representatives_.find(observed.bundle);
            if (representative == candidate.mapping.representatives_.end()) {
                if (candidate.mapping.nonnull_bundle_groups() >= maximum_bundle_groups) {
                    result.status_ = SourceIdentityStatus::cache_limit; return result;
                }
                representative = candidate.mapping.representatives_.emplace(observed.bundle, source).first;
            }
            candidate.ledger_key = representative->second;
            candidate.has_bundle_group = true; candidate.bundle_group = representative->second;
        } else {
            if (!candidate.mapping.has_nil_representative_) {
                candidate.mapping.has_nil_representative_ = true; candidate.mapping.nil_representative_ = source;
            }
            candidate.ledger_key = candidate.mapping.nil_representative_;
        }
        result.data_ = std::move(candidate); result.status_ = SourceIdentityStatus::complete;
    } catch (const std::bad_alloc &) { result.status_ = SourceIdentityStatus::allocation_failure; }
    catch (const std::length_error &) { result.status_ = SourceIdentityStatus::allocation_failure; }
    return result;
}

// Lookup must be obtained at THIS native call point if requested, not prefetched
// and permanently frozen at admission. A real nil result is different from an
// absent observation. Unknown query errors must not be invented into nil by this
// function: the native adapter defines whether the original lookup returned nil.
inline SourceIdentityResult resolveSourceIdentity(
    const SleepSourceIdentityMap &original, std::int64_t source, bool provider_present,
    const SourceBundleLookup &lookup, std::size_t maximum_cached_sources = 10000,
    std::size_t maximum_bundle_groups = 10000) {
    SourceIdentityResult result;
    if (!maximum_cached_sources || !maximum_bundle_groups) {
        result.status_ = SourceIdentityStatus::invalid_configuration; return result;
    }
    if (original.cached_sources() > maximum_cached_sources ||
        original.nonnull_bundle_groups() > maximum_bundle_groups) {
        result.status_ = SourceIdentityStatus::cache_limit; return result;
    }
    try {
        SourceIdentityData candidate;
        candidate.mapping = original;
        candidate.ledger_key = source;
        if (provider_present) {
            auto cached = candidate.mapping.nonnull_bundles_.find(source);
            const std::string *bundle = nullptr;
            if (cached != candidate.mapping.nonnull_bundles_.end()) {
                bundle = &cached->second;
            } else if (lookup.kind == BundleLookupKind::not_observed) {
                return result;
            } else if (lookup.kind == BundleLookupKind::nonnull_bundle) {
                if (candidate.mapping.cached_sources() >= maximum_cached_sources) {
                    result.status_ = SourceIdentityStatus::cache_limit; return result;
                }
                // Empty nonnil NSString is still nonnil; do not substitute nil.
                bundle = &candidate.mapping.nonnull_bundles_.emplace(source, lookup.bundle).first->second;
            } else if (lookup.kind != BundleLookupKind::nil_bundle) {
                result.status_ = SourceIdentityStatus::invalid_lookup_state;
                return result;
            }
            if (bundle) {
                auto representative = candidate.mapping.representatives_.find(*bundle);
                if (representative == candidate.mapping.representatives_.end()) {
                    if (candidate.mapping.nonnull_bundle_groups() >= maximum_bundle_groups) {
                        result.status_ = SourceIdentityStatus::cache_limit; return result;
                    }
                    representative = candidate.mapping.representatives_.emplace(*bundle, source).first;
                }
                candidate.ledger_key = representative->second;
                candidate.has_bundle_group = true;
                candidate.bundle_group = representative->second;
            } else {
                // Nil bundles share a representative in sourceKey, but multi
                // ledger update skips nil bundle groups. Single still uses key.
                if (!candidate.mapping.has_nil_representative_) {
                    candidate.mapping.has_nil_representative_ = true;
                    candidate.mapping.nil_representative_ = source;
                }
                candidate.ledger_key = candidate.mapping.nil_representative_;
            }
        }
        // Provider absent bypasses reverse maps and returns original sourceID.
        result.data_ = std::move(candidate);
        result.status_ = SourceIdentityStatus::complete;
    } catch (const std::bad_alloc &) { result.status_ = SourceIdentityStatus::allocation_failure; }
    catch (const std::length_error &) { result.status_ = SourceIdentityStatus::allocation_failure; }
    return result;
}

} }
#endif
