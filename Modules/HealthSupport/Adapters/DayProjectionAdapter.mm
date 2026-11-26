#include "DayProjectionAdapter.hpp"

#import "DayBuilderSnapshot.h"
#import "RuntimeTypeChecks.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <new>
#include <stdexcept>
#include <vector>

@protocol WFHSGoalSample
- (id)quantity;
@end

@protocol WFHSInBedSegmentBuilder
- (instancetype)initWithCategory:(NSInteger)category;
- (void)addOrderedSample:(id)sample;
- (NSArray *)finish;
@end

namespace watchfix { namespace healthsupport {
namespace {

bool declaredABI(Class cls, SEL selector, const char *encoding) {
    unsigned count = 0; Method *methods = class_copyMethodList(cls, &count);
    unsigned matches = 0; bool valid = false;
    for (unsigned i = 0; i < count; ++i) if (sel_isEqual(method_getName(methods[i]), selector)) {
        ++matches; const char *actual = method_getTypeEncoding(methods[i]);
        valid = actual && !std::strcmp(actual, encoding);
    }
    free(methods);
    return matches == 1 && valid;
}

// Same audit shape as LegacyPeriodAdapter: a stable native calendar is read
// twice and compared, and a copy is returned so later mutation of the cache
// cannot change the value stored in the summary.
NSCalendar *stableCalendar(id cache, Class auditedCacheClass) {
    if (!cache || object_getClass(cache) != auditedCacheClass) return nil;
    if (!declaredABI(auditedCacheClass, @selector(currentCalendar), "@16@0:8")) return nil;
    NSCalendar *first = [(id)cache currentCalendar];
    if (!WFHSActuallyInheritsFrom(first, NSCalendar.class)) return nil;
    NSCalendar *copy = [first copy];
    NSCalendar *second = [(id)cache currentCalendar];
    if (!WFHSActuallyInheritsFrom(copy, NSCalendar.class) ||
        !WFHSActuallyInheritsFrom(second, NSCalendar.class) || ![second isEqual:first]) return nil;
    return copy;
}

// Drives the audited native InBed segment builder with the day's original
// category0 objects. Returns nil on any structural mismatch; the caller then
// refuses to emit a summary instead of inventing InBed data.
NSArray *buildInBedSegments(NSArray *samples, const DayProjectionClasses &classes,
                            std::size_t maximum_segments) {
    if (!WFHSActuallyInheritsFrom(samples, NSArray.class) || samples.count > maximum_segments) return nil;
    Class builderClass = classes.segment_builder, segmentClass = classes.segment;
    if (!declaredABI(builderClass, @selector(initWithCategory:), "@24@0:8q16") ||
        !declaredABI(builderClass, @selector(addOrderedSample:), "v24@0:8@16") ||
        !declaredABI(builderClass, @selector(finish), "@16@0:8")) return nil;
    id allocated = [builderClass alloc];
    if (object_getClass(allocated) != builderClass) return nil;
    id<WFHSInBedSegmentBuilder> builder = [(id)allocated initWithCategory:0];
    if (object_getClass(builder) != builderClass) return nil;
    for (id sample in samples) {
        if (!WFHSActuallyInheritsFrom(sample, classes.sample)) return nil;
        [builder addOrderedSample:sample];
    }
    id finished = [builder finish];
    if (!WFHSActuallyInheritsFrom(finished, NSArray.class) || [finished count] > samples.count) return nil;
    for (id segment in finished) {
        if (object_getClass(segment) != segmentClass) return nil;
    }
    return [[NSArray alloc] initWithArray:finished];
}

} // namespace

DayProjectionAttempt projectSleepDaySummary(id builder, const DayProjectionClasses &classes,
                                            std::size_t maximum_samples, std::size_t maximum_segments) {
    DayProjectionAttempt result;
    if (!maximum_samples || !maximum_segments) {
        result.status = DayProjectionStatus::invalid_configuration; return result;
    }
    if (!classes.builder || !classes.calendar_cache || !classes.sample || !classes.category_type ||
        !classes.source_revision || !classes.source || !classes.segment || !classes.period_builder ||
        !classes.period || !classes.summary || !classes.segment_builder) {
        result.status = DayProjectionStatus::invalid_configuration; return result;
    }
    try {
        @try {
            WFHSDaySnapshot *snapshot = WFHSReadDayBuilderSnapshot(builder, classes.builder,
                                                                   classes.calendar_cache, maximum_samples);
            if (!snapshot || snapshot.status != WFHSDaySnapshotComplete) {
                // Nothing was read, so returning to native changes nothing.
                result.status = DayProjectionStatus::snapshot_failed; return result;
            }
            const auto presence = inspectSleepStagePresence(snapshot.sleepAnalysisSamples, classes.sample,
                                                            classes.category_type, maximum_samples);
            if (presence.status != SleepSampleStatus::complete) {
                result.status = DayProjectionStatus::input_failed;
                result.native_fallback_safe = false;
                return result;
            }
            result.has_stages = presence.has_stages;
            result.native_fallback_safe = !presence.has_stages;
            if (!presence.has_stages) {
                result.status = DayProjectionStatus::no_stages; return result;
            }
            const auto input = readSleepSampleSnapshot(snapshot.sleepAnalysisSamples, classes.sample,
                classes.category_type, classes.source_revision, classes.source, maximum_samples);
            if (!input.complete()) {
                result.status = DayProjectionStatus::input_failed; return result;
            }

            // Overlapping fragments are resolved by the audited per-slice
            // decision instead of refusing the whole day. A day without
            // overlap keeps its exact input list.
            SliceCompetitionConfiguration competitionConfiguration;
            competitionConfiguration.maximum_fragments = maximum_segments;
            competitionConfiguration.maximum_slices = maximum_segments;
            const SliceCompetitionResult competition =
                competeStageSlices(input.non_in_bed, competitionConfiguration);
            if (!competition.complete()) {
                result.status = competition.status == SliceCompetitionStatus::input_limit
                    ? DayProjectionStatus::resource_limit : DayProjectionStatus::statistics_failed;
                return result;
            }
            result.resolved_overlap = competition.competed;
            ProjectionConfiguration configuration;
            configuration.maximum_intervals = maximum_segments;
            const LegacyProjection projection = projectLegacySleepSummary(
                competition.intervals, StatisticsInputState::resolved_statistics_intervals, configuration);
            if (!projection.complete()) {
                result.status = DayProjectionStatus::statistics_failed; return result;
            }

            NSArray *inBed = buildInBedSegments(input.original_in_bed, classes, maximum_segments);
            if (!inBed) { result.status = DayProjectionStatus::in_bed_failed; return result; }

            // Native computes this flag as the OR of
            // [[[sample sourceRevision] source] _isAppleWatch] over the samples
            // that formed the segment. A derived segment exists only because raw
            // 3/4/5 are present, and on this OS a 15.4 client cannot write those
            // values: the only producer is Apple Watch, so the constant is exact.
            // If a non-watch stage source ever becomes reachable, this must
            // become a per-segment OR instead of a constant.
            const LegacyPeriodAttempt periods = makeLegacySleepPeriods(projection, inBed,
                /*apple_tracking_origin_known=*/true, /*contains_apple_tracking=*/true,
                classes.segment, classes.period_builder, classes.period, maximum_segments, maximum_segments);
            if (!periods.complete()) { result.status = DayProjectionStatus::periods_failed; return result; }
            if (!periods.periods.count) { result.status = DayProjectionStatus::output_failed; return result; }

            NSCalendar *calendar = stableCalendar(snapshot.calendarCache, classes.calendar_cache);
            if (!calendar) { result.status = DayProjectionStatus::metadata_invalid; return result; }

            // Audited native argument is [[_sleepDurationGoalSamples lastObject]
            // quantity], a value object rather than the sample. Several goals are
            // legitimate (the user changed the goal); the last one wins.
            id goal = nil;
            NSArray *goals = snapshot.sleepDurationGoalSamples;
            if (goals.count) {
                id last = goals.lastObject;
                if (!last || !class_getInstanceMethod(object_getClass(last), @selector(quantity))) {
                    result.status = DayProjectionStatus::metadata_invalid; return result;
                }
                goal = [(id<WFHSGoalSample>)last quantity];
            }

            const LegacyDaySummaryAttempt summary = makeLegacyDaySummaryWithMetadata(
                snapshot.morningIndex, snapshot.dateInterval, calendar, periods,
                snapshot.sleepScheduleSamples, goal, classes.summary, classes.period, maximum_segments);
            if (!summary.complete()) { result.status = DayProjectionStatus::output_failed; return result; }
            result.summary = summary.summary;
            result.status = DayProjectionStatus::complete;
        } @catch (NSException *candidateException) {
            (void)candidateException;
            result.summary = nil;
            result.status = DayProjectionStatus::candidate_exception;
        }
    } catch (const std::bad_alloc &) {
        result.summary = nil; result.status = DayProjectionStatus::resource_limit;
    } catch (const std::length_error &) {
        result.summary = nil; result.status = DayProjectionStatus::resource_limit;
    } catch (...) {
        result.summary = nil; result.status = DayProjectionStatus::candidate_exception;
    }
    return result;
}

} }
