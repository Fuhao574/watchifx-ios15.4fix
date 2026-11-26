// Uses the same series orchestration as the stable fixture path, with fresh
// bucket-owned source contexts and lookups at actual admission/advance points.
#ifndef WFHS_CONSUMPTION_SLEEP_SERIES_HPP
#define WFHS_CONSUMPTION_SLEEP_SERIES_HPP
#include "StableSleepSeries.hpp"
#include "SleepSourceConsumptionContext.hpp"

namespace watchfix { namespace healthsupport {

using BucketOrderingFactory = std::function<RegisteredPendingOrdering()>;

inline StableSeriesResult calculateConsumptionSleepSeries(
    const std::vector<StageFragment> &samples, const std::vector<CalendarBucketBounds> &bounds,
    StableSeriesInputState input_state, const StableSeriesConfiguration &configuration,
    const RegisteredPendingOrdering &order,
    const SleepSourceConsumptionContext::ProviderPresence &present,
    const SleepSourceConsumptionContext::Lookup &lookup,
    const BucketOrderingFactory *ordering_factory = nullptr) {
    try {
    // One whole-call byte budget, independent from fresh per-bucket maps.
    // Old/new contexts can coexist at rollover; resetting a map does not grant
    // another series budget. Failed entire calls discard this local counter.
    std::size_t remaining_bytes = configuration.maximum_total_bundle_bytes;
    SleepSourceConsumptionContext::Lookup bounded_lookup = [&](std::int64_t source) {
        auto observed = lookup(source);
        if (observed.kind == BundleLookupKind::nonnull_bundle) {
            if (observed.bundle.size() > configuration.maximum_bundle_bytes || observed.bundle.size() > remaining_bytes)
                return SourceBundleLookup{};
            remaining_bytes -= observed.bundle.size();
        }
        return observed;
    };
    SeriesSourceSessionFactory sessions = [&] {
        SeriesSourceSession session;
        auto context = std::make_shared<SleepSourceConsumptionContext>(configuration.bucket.maximum_keys,
            configuration.maximum_bundle_bytes, configuration.maximum_total_bundle_bytes);
        session.owner = context;
        if (ordering_factory) session.order = (*ordering_factory)();
        session.consumption = context->callbacks(present, bounded_lookup);
        const auto key = session.consumption.key;
        session.identity = [key](std::int64_t source) {
            AdmissionSourceIdentity identity;
            const auto resolved = key(source);
            identity.resolved = resolved.resolved; identity.ledger_key = resolved.key;
            // Admission creates the empty ledger only. No extra bundle call:
            // actual multi gating resolves its own current group later.
            return identity;
        };
        return session;
    };
    // provider_present=false only disables the stable prefetch contract. Actual
    // provider presence is queried by the consumption callbacks, never frozen.
    return calculateStableSleepSeries(samples, bounds, {}, false, input_state,
        configuration, order, &sessions);
    } catch (const std::bad_alloc &) { return StableSeriesResult::allocationFailure(); }
    catch (const std::length_error &) { return StableSeriesResult::allocationFailure(); }
}

} }
#endif
