// Objective-C++ offline integration only. No sample reads, runtime hooks or
// native class discovery. Audited SDK sort header opt-in is required by build.
#ifndef WFHS_STABLE_SERIES_ADAPTER_HPP
#define WFHS_STABLE_SERIES_ADAPTER_HPP

#import "CalendarBucketAdapter.h"
#import "SourceProviderAdapter.h"
#include "StableSleepSeries.hpp"

namespace watchfix { namespace healthsupport {

enum class StableAdapterStatus {
    complete,
    unresolved_prerequisites,
    invalid_configuration,
    invalid_sample,
    unordered_samples,
    resource_limit,
    calendar_failed,
    source_lookup_failed,
    series_failed,
    allocation_failure,
    candidate_exception
};

struct StableAdapterResult {
    StableAdapterStatus status = StableAdapterStatus::unresolved_prerequisites;
    // Data is accessible only through the underlying complete-only result.
    StableSeriesResult series;
    bool complete() const noexcept { return status == StableAdapterStatus::complete && series.complete(); }
};

// STRICT PRECONDITIONS: valid loaded objects/classes, exact verified native
// build/image/owner/IMP/ABI, stable objects/getters/provider for whole operation,
// no key override, strategy0, empty mask, audited calendar anchor/components.
// This API does NOT establish those facts. Passing the enum is not verification.
// Snapshotting source descriptions is only equivalent in the declared STABLE
// subcase, not a dynamic mapping implementation. Ranking refreshes per actual
// multi ordering callback; bundle lookups here occur once per distinct source.
// Provider nil is intentional provider absence; nonnil failed lookup never
// becomes absent/nil. All raw fragments are caller supplied, not read here.
// Inputs are synchronously borrowed; no callbacks escape or objects persist.
StableAdapterResult calculateStableSleepSeriesWithAdapters(
    const std::vector<StageFragment> &samples,
    id collection, Class auditedCollectionClass, std::int64_t first_index, NSUInteger bucket_count,
    id provider, Class auditedProviderClass, StableSeriesInputState prerequisites,
    const StableSeriesConfiguration &configuration);

// Same audited object prerequisites, but bundle descriptions are NOT prefetched.
// Nonnull cache/nil relookup/key resolution run at actual consumption points.
// This bridge pins the provided provider for the synchronous call; it supports
// changing lookup results, NOT arbitrary native weak-provider disappearance.
// Core callbacks separately model those weak-load points, not yet bound here.
StableAdapterResult calculateConsumptionSleepSeriesWithAdapters(
    const std::vector<StageFragment> &samples,
    id collection, Class auditedCollectionClass, std::int64_t first_index, NSUInteger bucket_count,
    id provider, Class auditedProviderClass, StableSeriesInputState prerequisites,
    const StableSeriesConfiguration &configuration);
// RawFeedCalendarPlan supplies these complete visited buckets, including allowed
// empty-carry index jumps. No extra collection reread or fixed-day expansion.
StableAdapterResult calculateConsumptionSleepBoundsWithAdapters(
    const std::vector<StageFragment> &samples, const std::vector<CalendarBucketBounds> &bounds,
    id provider, Class auditedProviderClass, StableSeriesInputState prerequisites,
    const StableSeriesConfiguration &configuration);

} }
#endif
