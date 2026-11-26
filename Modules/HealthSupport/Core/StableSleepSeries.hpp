// Shared finite series orchestration. Stable descriptions remain supported;
// consumption-point sessions are opt-in and privately owned per bucket.
// Explicit contiguous calendar buckets only. Not a live HealthKit query adapter.
#ifndef WATCHFIX_HEALTH_SUPPORT_STABLE_SLEEP_SERIES_HPP
#define WATCHFIX_HEALTH_SUPPORT_STABLE_SLEEP_SERIES_HPP

#include "SleepBucketRollover.hpp"
#include "SleepSourceIdentityMap.hpp"
#include "SleepStatisticsBucketOutput.hpp"
#include <algorithm>
#include <functional>
#include <map>
#include <memory>
#include <new>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace watchfix { namespace healthsupport {

struct StableSourceDescription {
    std::int64_t source_id;
    // Only actual nonnil/nil lookup results permitted. not_observed is an
    // unsupported source, NOT a nil fallback. Bundle bytes are adapter supplied.
    SourceBundleLookup bundle_lookup;
};

enum class StableSeriesInputState {
    unresolved_native_input, audited_stable_source_descriptions,
    audited_consumption_point_callbacks
};

// Private per-bucket callback context. Keep its owner alive until the old bucket
// is finished AND the next bucket's carry replay is complete. Not a native
// enumerator/builder association or runtime proof.
struct SeriesSourceSession {
    std::shared_ptr<void> owner;
    AdmissionIdentity identity;
    SourceConsumption consumption;
    RegisteredPendingOrdering order;
};
using SeriesSourceSessionFactory = std::function<SeriesSourceSession()>;

struct StableSeriesConfiguration {
    BucketAdvanceConfiguration bucket;
    SplitOrder bucket_end_split_order = SplitOrder::numeric_one;
    std::size_t maximum_samples = 100000;
    std::size_t maximum_buckets = 10000;
    std::size_t maximum_bundle_bytes = 4096;
    std::size_t maximum_total_bundle_bytes = 4 * 1024 * 1024;
    // Only bounds obtained from audited RawFeedCalendarPlan. Allows gaps when
    // raw carry is empty; never skips carry or supplies day-wide blank buckets.
    bool raw_feed_calendar_routing = false;
};

enum class StableSeriesStatus {
    complete,
    unresolved_input,
    invalid_configuration,
    resource_limit,
    invalid_calendar_bounds,
    invalid_sample,
    unordered_samples,
    sample_outside_supplied_range,
    invalid_source_description,
    missing_source_description,
    admission_failed,
    rollover_failed,
    final_advance_failed,
    output_failed,
    unconsumed_tail,
    allocation_failure,
    adapter_failure
};

struct StableSeriesData {
    // One entry per supplied bucket, including explicit no-stage decisions.
    // Native empty-bucket emission policy is NOT implemented by this vector.
    std::vector<BucketOutput> buckets;
    std::vector<StageStatisticsInterval> resolved_intervals;
    std::size_t admitted_raw_occurrences = 0;
};

class StableSeriesResult;
StableSeriesResult calculateStableSleepSeries(const std::vector<StageFragment> &,
    const std::vector<CalendarBucketBounds> &, const std::vector<StableSourceDescription> &,
    bool, StableSeriesInputState, const StableSeriesConfiguration &, const RegisteredPendingOrdering &,
    const SeriesSourceSessionFactory *);

class StableSeriesResult {
public:
    static StableSeriesResult allocationFailure() {
        StableSeriesResult result; result.status_ = StableSeriesStatus::allocation_failure; return result;
    }
    StableSeriesStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == StableSeriesStatus::complete; }
    const StableSeriesData *data() const noexcept { return complete() ? &data_ : nullptr; }
private:
    StableSeriesStatus status_ = StableSeriesStatus::unresolved_input;
    StableSeriesData data_;
    friend StableSeriesResult calculateStableSleepSeries(const std::vector<StageFragment> &,
        const std::vector<CalendarBucketBounds> &, const std::vector<StableSourceDescription> &,
        bool, StableSeriesInputState, const StableSeriesConfiguration &, const RegisteredPendingOrdering &,
        const SeriesSourceSessionFactory *);
};

// Without source_sessions the callback implements audited source ranking/start sorting; its registered
// IDs refresh each admission/advance. provider_present and descriptions MUST
// remain stable throughout this call. Dynamic provider/nil->nonnull changes are
// outside this controller, not silently approximated by frozen keys.
// Fixed native configuration prerequisites: strategy0, no external source-key
// override and advance-before-enqueue=true. The stable-input enum does not
// establish those native facts; a production adapter must verify them.
// All own source maps are private per-call and per-bucket, so failed calculations
// do not commit representative/cache choices. External order effects are NOT
// rolled back and must be isolated by the caller.
// With source_sessions: create fresh private contexts per bucket, use old
// consumption to finish old state and new consumption to replay raw carry.
// Session creation itself must NOT fetch/cache bundles or change representative
// selection. The stable provider_present/descriptions parameters do not apply.
inline StableSeriesResult calculateStableSleepSeries(
    const std::vector<StageFragment> &samples, const std::vector<CalendarBucketBounds> &bounds,
    const std::vector<StableSourceDescription> &descriptions, bool provider_present,
    StableSeriesInputState input_state, const StableSeriesConfiguration &configuration,
    const RegisteredPendingOrdering &order, const SeriesSourceSessionFactory *source_sessions = nullptr) {
    StableSeriesResult result;
    const bool dynamic = source_sessions != nullptr;
    if ((!dynamic && input_state != StableSeriesInputState::audited_stable_source_descriptions) ||
        (dynamic && input_state != StableSeriesInputState::audited_consumption_point_callbacks)) return result;
    if (dynamic && (!*source_sessions || !descriptions.empty())) return result;
    if (!configuration.maximum_samples || !configuration.maximum_buckets ||
        !configuration.maximum_bundle_bytes || !configuration.maximum_total_bundle_bytes ||
        !configuration.bucket.maximum_pending || !configuration.bucket.maximum_keys ||
        !configuration.bucket.maximum_steps || !configuration.bucket.mask_is_empty ||
        !std::isfinite(configuration.bucket.merge_granularity) || configuration.bucket.merge_granularity <= 0 ||
        (configuration.bucket_end_split_order != SplitOrder::numeric_zero &&
         configuration.bucket_end_split_order != SplitOrder::numeric_one)) {
        result.status_ = StableSeriesStatus::invalid_configuration; return result;
    }
    if (samples.size() > configuration.maximum_samples || bounds.size() > configuration.maximum_buckets ||
        descriptions.size() > configuration.bucket.maximum_keys) {
        result.status_ = StableSeriesStatus::resource_limit; return result;
    }
    if (bounds.empty()) { result.status_ = StableSeriesStatus::invalid_calendar_bounds; return result; }
    for (std::size_t i = 0; i < bounds.size(); ++i) {
        if (!std::isfinite(bounds[i].start) || !std::isfinite(bounds[i].end) || bounds[i].end <= bounds[i].start ||
            !std::isfinite(bounds[i].end - bounds[i].start) || (i &&
                (configuration.raw_feed_calendar_routing ? bounds[i].start<bounds[i-1].end : bounds[i].start!=bounds[i-1].end))) {
            result.status_ = StableSeriesStatus::invalid_calendar_bounds; return result;
        }
    }
    for (std::size_t i = 0; i < samples.size(); ++i) {
        const auto &sample = samples[i];
        if (sample.category < 1 || sample.category > 5 || !std::isfinite(sample.start) ||
            !std::isfinite(sample.end) || sample.end <= sample.start || !std::isfinite(sample.end - sample.start)) {
            result.status_ = StableSeriesStatus::invalid_sample; return result;
        }
        if (i && sample.start < samples[i - 1].start) {
            result.status_ = StableSeriesStatus::unordered_samples; return result;
        }
        // This finite controller requires enough explicit buckets to cover the
        // input end. A query-range clipping policy is a separate native adapter
        // contract; do not publish an unnoticed partial tail as complete.
        if (sample.start >= bounds.back().end || (!configuration.raw_feed_calendar_routing && sample.end > bounds.back().end)) {
            result.status_ = StableSeriesStatus::sample_outside_supplied_range; return result;
        }
    }
    try {
        std::map<std::int64_t, SourceBundleLookup> lookup_by_source;
        std::size_t remaining_bytes = configuration.maximum_total_bundle_bytes;
        for (const auto &description : descriptions) {
            const auto &lookup = description.bundle_lookup;
            if (lookup.kind != BundleLookupKind::nonnull_bundle && lookup.kind != BundleLookupKind::nil_bundle) {
                result.status_ = StableSeriesStatus::invalid_source_description; return result;
            }
            if (lookup.bundle.size() > configuration.maximum_bundle_bytes || lookup.bundle.size() > remaining_bytes) {
                result.status_ = StableSeriesStatus::resource_limit; return result;
            }
            remaining_bytes -= lookup.bundle.size();
            if (!lookup_by_source.emplace(description.source_id, lookup).second) {
                result.status_ = StableSeriesStatus::invalid_source_description; return result;
            }
        }
        if (!dynamic && provider_present) for (const auto &sample : samples) {
            if (!lookup_by_source.count(sample.source_id)) {
                result.status_ = StableSeriesStatus::missing_source_description; return result;
            }
        }
        const auto ordered = PendingOrderState::native_equivalent_source_then_start_order;
        const auto mapped = SourceKeyState::canonicalized_in_one_mapping_session;
        StableSeriesData candidate;
        BucketLifecycleState current{bounds.front(), {}, {}, {}};
        current.statistics.current = bounds.front().start;
        current.statistics.interval_end = bounds.front().end;
        SleepSourceIdentityMap mapping;
        AdmissionIdentity identity = [&](std::int64_t source) {
            SourceBundleLookup lookup;
            if (provider_present) lookup = lookup_by_source.at(source);
            auto resolved = resolveSourceIdentity(mapping, source, provider_present, lookup,
                                                   configuration.bucket.maximum_keys, configuration.bucket.maximum_keys);
            AdmissionSourceIdentity value;
            if (!resolved.complete()) return value;
            mapping = resolved.data()->mapping;
            value.resolved = true; value.ledger_key = resolved.data()->ledger_key;
            value.has_bundle_group = resolved.data()->has_bundle_group;
            value.bundle_group = resolved.data()->bundle_group;
            return value;
        };
        auto publish_bucket = [&](const SleepBucketState &state, CalendarBucketBounds interval) {
            auto output = finalizeSleepStatisticsBucket(state.total, interval, true);
            if (!output.succeeded()) return false;
            if (output.interval()) candidate.resolved_intervals.push_back(*output.interval());
            candidate.buckets.push_back(output);
            return true;
        };
        std::size_t sample_index = 0;
        SeriesSourceSession session;
        if (dynamic) session = (*source_sessions)();
        for (std::size_t bucket = 0; bucket < bounds.size(); ++bucket) {
            while (sample_index < samples.size() && samples[sample_index].start < current.bounds.end) {
                if(configuration.raw_feed_calendar_routing && samples[sample_index].start<current.bounds.start) {
                    result.status_=StableSeriesStatus::sample_outside_supplied_range;return result;
                }
                auto admitted = admitRawStageToBucket(current, samples[sample_index], true,
                    configuration.bucket_end_split_order, configuration.bucket, ordered, mapped,
                    dynamic && session.order ? session.order : order,
                    dynamic ? session.identity : identity, dynamic ? &session.consumption : nullptr);
                if (!admitted.complete()) { result.status_ = StableSeriesStatus::admission_failed; return result; }
                current = *admitted.state();
                ++sample_index; ++candidate.admitted_raw_occurrences;
            }
            if (bucket + 1 < bounds.size()) {
                // The new bucket is initialized BEFORE replay, with fresh maps;
                // this does not touch old pending already carrying stable keys.
                SeriesSourceSession next_session;
                if (dynamic) next_session = (*source_sessions)();
                else mapping = SleepSourceIdentityMap();
                auto rolled = rolloverSleepBucket(current, bounds[bucket + 1], configuration.bucket_end_split_order,
                    configuration.bucket, ordered, mapped, dynamic && session.order ? session.order : order,
                    dynamic ? next_session.identity : identity,
                    dynamic ? &session.consumption : nullptr, dynamic ? &next_session.consumption : nullptr,
                    dynamic && next_session.order ? &next_session.order : nullptr, configuration.raw_feed_calendar_routing);
                if (!rolled.complete()) { result.status_ = StableSeriesStatus::rollover_failed; return result; }
                // Advance completion is not pending exhaustion. This finite
                // controller cannot silently lose residual old pending when
                // accepting a rollover. Do not turn it into carry or force
                // another advance; raw carry has a different audited lifecycle.
                if (!rolled.data()->finished_previous.pending.empty()) {
                    result.status_ = StableSeriesStatus::unconsumed_tail; return result;
                }
                if (!publish_bucket(rolled.data()->finished_previous, current.bounds)) {
                    result.status_ = StableSeriesStatus::output_failed; return result;
                }
                current = rolled.data()->next;
                if (dynamic) session = std::move(next_session);
            } else {
                PendingOrdering final_order;
                const auto &current_order = dynamic && session.order ? session.order : order;
                if (current_order) final_order = [&](const std::vector<MappedPendingStage> &pending) {
                    return current_order(pending, current.registered_source_ids);
                };
                auto final = advanceSleepBucket(current.statistics, current.bounds.end, configuration.bucket,
                                                 ordered, mapped, final_order, dynamic ? &session.consumption : nullptr);
                if (!final.complete()) { result.status_ = StableSeriesStatus::final_advance_failed; return result; }
                if (!current.raw_carry.empty() || sample_index != samples.size() || !final.data()->state.pending.empty()) {
                    result.status_ = StableSeriesStatus::unconsumed_tail; return result;
                }
                if (!publish_bucket(final.data()->state, current.bounds)) {
                    result.status_ = StableSeriesStatus::output_failed; return result;
                }
            }
        }
        result.data_ = std::move(candidate);
        result.status_ = StableSeriesStatus::complete;
    } catch (const std::bad_alloc &) { result.status_ = StableSeriesStatus::allocation_failure; }
    catch (const std::length_error &) { result.status_ = StableSeriesStatus::allocation_failure; }
    catch (...) { result.status_ = StableSeriesStatus::adapter_failure; }
    return result;
}

} }
#endif
