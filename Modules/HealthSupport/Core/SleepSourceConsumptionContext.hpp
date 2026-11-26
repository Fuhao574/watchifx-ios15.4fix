// Actual consumption-point cache/key binding. No provider is invented here;
// caller supplies current weak-provider presence and actual bundle results.
#ifndef WFHS_SLEEP_SOURCE_CONSUMPTION_CONTEXT_HPP
#define WFHS_SLEEP_SOURCE_CONSUMPTION_CONTEXT_HPP
#include "SleepSourceIdentityMap.hpp"
#include "SleepMultiSourceAdvance.hpp"
#include <limits>

namespace watchfix { namespace healthsupport {

class SleepSourceConsumptionContext {
public:
    using ProviderPresence = std::function<bool()>;
    using Lookup = std::function<SourceBundleLookup(std::int64_t)>;
    SleepSourceConsumptionContext(std::size_t maximum_sources = 10000, std::size_t maximum_bundle_bytes = 4096,
                                  std::size_t maximum_total_bytes = 4 * 1024 * 1024)
        : maximum_sources_(maximum_sources), maximum_bundle_bytes_(maximum_bundle_bytes), remaining_bytes_(maximum_total_bytes) {}

    // Call only on a PRIVATE stage context for the entire admission/advance/
    // rollover; callbacks do not own or publish shared state. On operation
    // failure discard this context along with returned bucket state. Native
    // provider side effects cannot be rolled back. Copying it stages cache/maps;
    // no old-bucket context is reused for new-bucket replay.
    SourceConsumption callbacks(const ProviderPresence &present, const Lookup &lookup) {
        SourceConsumption result;
        result.bundle = [this, present, lookup](std::int64_t source) {
            ConsumptionBundle value;
            if (!maximum_sources_ || !maximum_bundle_bytes_) return value;
            auto bundle = observeAtNativePoint(source, present, lookup);
            if (!bundle.complete()) return value;
            if (bundle.bundle()) {
                auto group = groups_.find(*bundle.bundle());
                if (group == groups_.end()) {
                    if (groups_.size() >= maximum_sources_ || groups_.size() >= static_cast<std::size_t>(INT64_MAX)) return value;
                    group = groups_.emplace(*bundle.bundle(), static_cast<std::int64_t>(groups_.size())).first;
                }
                value.nonnull = true; value.group = group->second;
            }
            mapping_ = *bundle.mapping(); value.resolved = true; return value;
        };
        result.key = [this, present, lookup](std::int64_t source) {
            ConsumptionKey value;
            if (!maximum_sources_ || !maximum_bundle_bytes_) return value;
            // sourceKey's outer weak load is distinct from the nested bundle
            // helper load, and from the later getter load on a cache miss.
            if (!present()) { value.resolved = true; value.key = source; return value; }
            auto bundle = observeAtNativePoint(source, present, lookup);
            if (!bundle.complete()) return value;
            mapping_ = *bundle.mapping();
            SourceBundleLookup observed{BundleLookupKind::nil_bundle, {}};
            if (bundle.bundle()) observed = {BundleLookupKind::nonnull_bundle, *bundle.bundle()};
            auto identity = resolveSourceKeyFromObservedBundle(mapping_, source, observed, maximum_sources_);
            if (!identity.complete()) return value;
            mapping_ = identity.data()->mapping; value.resolved = true; value.key = identity.data()->ledger_key; return value;
        };
        return result;
    }
    const SleepSourceIdentityMap &mapping() const noexcept { return mapping_; }
private:
    SourceBundleObservation observeAtNativePoint(std::int64_t source, const ProviderPresence &present, const Lookup &lookup) {
        const bool helper_provider = present();
        SourceBundleLookup observed;
        if (mapping_.needs_bundle_lookup(source, helper_provider)) {
            // Native reacquires weak provider once more for the actual source
            // getter after a cache miss. A nil receiver yields actual nil.
            observed = present() ? checkedLookup(source, lookup) : SourceBundleLookup{BundleLookupKind::nil_bundle, {}};
        }
        return observeSourceBundle(mapping_, source, helper_provider, observed, maximum_sources_);
    }
    SourceBundleLookup checkedLookup(std::int64_t source, const Lookup &lookup) {
        auto result = lookup(source);
        if (result.kind == BundleLookupKind::nonnull_bundle) {
            if (result.bundle.size() > maximum_bundle_bytes_ || result.bundle.size() > remaining_bytes_) return {};
            remaining_bytes_ -= result.bundle.size();
        }
        return result;
    }
    SleepSourceIdentityMap mapping_;
    // Group tokens are only equality keys within this mapping session. They
    // are NOT ledger representatives or native source IDs and never persisted.
    std::map<std::string, std::int64_t> groups_;
    std::size_t maximum_sources_, maximum_bundle_bytes_, remaining_bytes_;
};

} }
#endif
