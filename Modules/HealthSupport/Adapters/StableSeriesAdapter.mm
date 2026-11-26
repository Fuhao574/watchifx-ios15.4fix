#include "StableSeriesAdapter.hpp"
#include "PinnedSleepPendingOrder.hpp"
#include "ConsumptionSleepSeries.hpp"
#include "PinnedSleepSourceRanks.hpp"
#import "RuntimeTypeChecks.h"
#include <set>

namespace watchfix { namespace healthsupport {
namespace {
struct AdapterCallFailure {};
}

static StableAdapterResult calculateSeriesWithAdapters(
    const std::vector<StageFragment> &samples,
    id collection, Class auditedCollectionClass, std::int64_t first_index, NSUInteger bucket_count,
    id provider, Class auditedProviderClass, StableSeriesInputState prerequisites,
    const StableSeriesConfiguration &configuration, bool consumption_points,
    const std::vector<CalendarBucketBounds> *planned_bounds = nullptr) {
    StableAdapterResult result;
    if (prerequisites != (consumption_points ? StableSeriesInputState::audited_consumption_point_callbacks :
                                               StableSeriesInputState::audited_stable_source_descriptions)) return result;
    // Reject before any candidate call; failed configuration must not trigger
    // provider work simply because this adapter precedes the series controller.
    if (!configuration.maximum_samples || !configuration.maximum_buckets ||
        !configuration.maximum_bundle_bytes || !configuration.maximum_total_bundle_bytes ||
        !configuration.bucket.maximum_keys || !configuration.bucket.maximum_pending ||
        !configuration.bucket.maximum_steps || !configuration.bucket.mask_is_empty ||
        !std::isfinite(configuration.bucket.merge_granularity) || configuration.bucket.merge_granularity <= 0 ||
        (configuration.bucket_end_split_order != SplitOrder::numeric_zero &&
         configuration.bucket_end_split_order != SplitOrder::numeric_one)) {
        result.status = StableAdapterStatus::invalid_configuration; return result;
    }
    if (samples.size() > configuration.maximum_samples || bucket_count > configuration.maximum_buckets) {
        result.status = StableAdapterStatus::resource_limit; return result;
    }
    for (std::size_t i = 0; i < samples.size(); ++i) {
        const auto &raw = samples[i];
        if (raw.category < 1 || raw.category > 5 || !std::isfinite(raw.start) || !std::isfinite(raw.end) ||
            raw.end <= raw.start || !std::isfinite(raw.end - raw.start)) {
            result.status = StableAdapterStatus::invalid_sample; return result;
        }
        if (i && raw.start < samples[i - 1].start) {
            result.status = StableAdapterStatus::unordered_samples; return result;
        }
    }
    try {
        @try {
            std::vector<CalendarBucketBounds> bounds;
            if(planned_bounds) {
                bounds=*planned_bounds;
            } else {
            auto calendars = WFHSCollectCalendarBuckets(collection, auditedCollectionClass,
                first_index, bucket_count, configuration.maximum_buckets);
            if (!calendars || calendars.status != WFHSCalendarBucketComplete || !calendars.intervals ||
                calendars.intervals.count != bucket_count) {
                result.status = StableAdapterStatus::calendar_failed; return result;
            }
            bounds.reserve(bucket_count);
            for (NSDateInterval *interval in calendars.intervals) {
                // Calendar adapter's borrowed stable-value precondition extends
                // through this conversion. Core independently checks numbers.
                bounds.push_back({interval.startDate.timeIntervalSinceReferenceDate,
                                   interval.endDate.timeIntervalSinceReferenceDate});
            }
            }
            std::vector<StableSourceDescription> descriptions;
            const bool provider_present = provider != nil;
            if (provider_present && !consumption_points) {
                std::set<std::int64_t> seen;
                std::size_t remaining_bytes = configuration.maximum_total_bundle_bytes;
                for (const auto &raw : samples) {
                    if (!seen.insert(raw.source_id).second) continue;
                    if (seen.size() > configuration.bucket.maximum_keys) {
                        result.status = StableAdapterStatus::resource_limit; return result;
                    }
                    auto attempt = WFHSLookupSourceBundle(provider, auditedProviderClass, raw.source_id,
                                                          configuration.maximum_bundle_bytes);
                    if (!attempt || attempt.status != WFHSSourceProviderComplete) {
                        result.status = StableAdapterStatus::source_lookup_failed; return result;
                    }
                    SourceBundleLookup lookup{BundleLookupKind::nil_bundle, {}};
                    if (attempt.bundleIdentifier) {
                        NSData *bytes = [attempt.bundleIdentifier dataUsingEncoding:NSUTF8StringEncoding
                                                              allowLossyConversion:NO];
                        if (!WFHSActuallyInheritsFrom(bytes, NSData.class) ||
                            bytes.length > configuration.maximum_bundle_bytes || bytes.length > remaining_bytes ||
                            (bytes.length && !bytes.bytes)) {
                            result.status = StableAdapterStatus::source_lookup_failed; return result;
                        }
                        remaining_bytes -= bytes.length;
                        lookup.kind = BundleLookupKind::nonnull_bundle;
                        if (bytes.length) lookup.bundle.assign(static_cast<const char *>(bytes.bytes), bytes.length);
                    }
                    descriptions.push_back({raw.source_id, std::move(lookup)});
                }
            }
            RegisteredPendingOrdering order = [&](const std::vector<MappedPendingStage> &pending,
                                                   const std::vector<std::int64_t> &registered) {
                std::vector<std::int64_t> ranks;
                if (provider_present) {
                    NSMutableArray<NSNumber *> *ids = [NSMutableArray arrayWithCapacity:registered.size()];
                    if (!ids) throw AdapterCallFailure();
                    for (const auto source : registered) [ids addObject:@(source)];
                    auto ranked = WFHSOrderRegisteredSourceIDs(provider, auditedProviderClass, ids,
                                                               configuration.bucket.maximum_keys);
                    if (!ranked || ranked.status != WFHSSourceProviderComplete || !ranked.orderedSourceIDs)
                        throw AdapterCallFailure();
                    for (NSNumber *source in ranked.orderedSourceIDs) ranks.push_back(source.longLongValue);
                }
                auto sorted = orderSleepPending(pending, provider_present, ranks,
                    std::max(configuration.bucket.maximum_pending, configuration.bucket.maximum_keys));
                if (!sorted.complete()) throw AdapterCallFailure();
                return *sorted.permutation();
            };
            auto actual_lookup = [&](std::int64_t source) {
                auto attempt = WFHSLookupSourceBundle(provider, auditedProviderClass, source,
                                                      configuration.maximum_bundle_bytes);
                if (!attempt || attempt.status != WFHSSourceProviderComplete) throw AdapterCallFailure();
                SourceBundleLookup lookup{BundleLookupKind::nil_bundle, {}};
                if (attempt.bundleIdentifier) {
                    NSData *bytes = [attempt.bundleIdentifier dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
                    if (!WFHSActuallyInheritsFrom(bytes, NSData.class) || bytes.length > configuration.maximum_bundle_bytes ||
                        (bytes.length && !bytes.bytes)) throw AdapterCallFailure();
                    lookup.kind = BundleLookupKind::nonnull_bundle;
                    if (bytes.length) lookup.bundle.assign(static_cast<const char *>(bytes.bytes), bytes.length);
                }
                return lookup;
            };
            BucketOrderingFactory ordering_factory = [&] {
                auto cache = std::make_shared<PinnedSleepSourceRanks>();
                return RegisteredPendingOrdering([&,cache](const std::vector<MappedPendingStage> &pending,
                    const std::vector<std::int64_t> &registered) {
                    SourceRankProvider rank_provider = [&](const std::vector<std::int64_t> &unordered) {
                        NSMutableArray *ids = [NSMutableArray arrayWithCapacity:unordered.size()];
                        if (!ids) throw AdapterCallFailure();
                        for (auto source : unordered) [ids addObject:@(source)];
                        auto attempt = WFHSOrderRegisteredSourceIDs(provider, auditedProviderClass, ids,
                            configuration.bucket.maximum_keys);
                        if (!attempt || attempt.status != WFHSSourceProviderComplete) throw AdapterCallFailure();
                        std::vector<std::int64_t> ranks;
                        for (NSNumber *source in attempt.orderedSourceIDs) ranks.push_back(source.longLongValue);
                        return ranks;
                    };
                    const auto &ranks = cache->refresh(registered, provider_present, rank_provider, configuration.bucket.maximum_keys);
                    auto sorted = orderSleepPending(pending, provider_present, ranks,
                        std::max(configuration.bucket.maximum_pending, configuration.bucket.maximum_keys));
                    if (!sorted.complete()) throw AdapterCallFailure();
                    return *sorted.permutation();
                });
            };
            auto series = consumption_points ?
                calculateConsumptionSleepSeries(samples, bounds, prerequisites, configuration, order,
                    [provider_present] { return provider_present; }, actual_lookup, &ordering_factory) :
                calculateStableSleepSeries(samples, bounds, descriptions, provider_present,
                    prerequisites, configuration, order);
            if (!series.complete()) {
                result.status = StableAdapterStatus::series_failed; return result;
            }
            result.series = std::move(series);
            result.status = StableAdapterStatus::complete;
        } @catch (NSException *candidateException) {
            (void)candidateException;
            result.status = StableAdapterStatus::candidate_exception;
        }
    } catch (const std::bad_alloc &) { result.status = StableAdapterStatus::allocation_failure; }
    catch (const std::length_error &) { result.status = StableAdapterStatus::allocation_failure; }
    catch (...) { result.status = StableAdapterStatus::series_failed; }
    return result;
}

StableAdapterResult calculateStableSleepSeriesWithAdapters(
    const std::vector<StageFragment> &samples,
    id collection, Class auditedCollectionClass, std::int64_t first_index, NSUInteger bucket_count,
    id provider, Class auditedProviderClass, StableSeriesInputState prerequisites,
    const StableSeriesConfiguration &configuration) {
    return calculateSeriesWithAdapters(samples, collection, auditedCollectionClass, first_index, bucket_count,
        provider, auditedProviderClass, prerequisites, configuration, false);
}

StableAdapterResult calculateConsumptionSleepSeriesWithAdapters(
    const std::vector<StageFragment> &samples,
    id collection, Class auditedCollectionClass, std::int64_t first_index, NSUInteger bucket_count,
    id provider, Class auditedProviderClass, StableSeriesInputState prerequisites,
    const StableSeriesConfiguration &configuration) {
    return calculateSeriesWithAdapters(samples, collection, auditedCollectionClass, first_index, bucket_count,
        provider, auditedProviderClass, prerequisites, configuration, true);
}

StableAdapterResult calculateConsumptionSleepBoundsWithAdapters(
    const std::vector<StageFragment> &samples,const std::vector<CalendarBucketBounds> &bounds,
    id provider,Class auditedProviderClass,StableSeriesInputState prerequisites,
    const StableSeriesConfiguration &configuration) {
    return calculateSeriesWithAdapters(samples,nil,Nil,0,bounds.size(),provider,auditedProviderClass,
        prerequisites,configuration,true,&bounds);
}

} }
