#include "DaySummaryAdapter.hpp"
#import "RuntimeTypeChecks.h"

@protocol WFHSDayResultContext
- (NSInteger)morningIndex;
- (NSDateInterval *)dateInterval;
@end

namespace watchfix { namespace healthsupport {
DaySummaryAttempt createCompatibleDaySummary(id builder, WFHSQueryBinding *binding,
    const DaySummaryClasses &classes, std::size_t maximum_samples,
    bool tracking_origin_known, bool contains_apple_tracking,
    const DayStatistics &statistics, const NativeInBedSegments &in_bed,
    const GuardedOriginalDayCreate &original, const StableDayCalendar &calendar,
    const DayCreateAdmission &admission) {
    DaySummaryAttempt result;
    if (!binding || !maximum_samples || !original ||
        !classes.builder || !classes.calendar_cache || !classes.sample || !classes.category_type ||
        !classes.summary) return result;
    LegacyPeriodAttempt periods;
    WFHSDaySnapshot *snapshot = nil;
    bool has_stages = false;
    NSCalendar *native_calendar = nil;
    uint64_t binding_generation = 0;
    __attribute__((objc_precise_lifetime)) id bound_profile = nil, bound_cache = nil;
    try {
        @try {
            if(admission&&!admission()){result.status=DaySummaryStatus::operation_rejected;return result;}
            if (!hasLegacyDaySummaryABI(classes.summary)) return result;
            snapshot = WFHSReadDayBuilderSnapshot(builder, classes.builder, classes.calendar_cache, maximum_samples);
            if (!snapshot || snapshot.status != WFHSDaySnapshotComplete) { result.status = DaySummaryStatus::snapshot_failed; return result; }
            WFHSBoundDayContext *context = [binding contextForBuilder:builder actualCache:snapshot.calendarCache];
            if (!context || !context.profile) return result;
            binding_generation = context.generation;
            bound_profile = context.profile; bound_cache = context.calendarCache;
            if (!bound_profile || bound_cache != snapshot.calendarCache) return result;
            const auto presence = inspectSleepStagePresence(snapshot.sleepAnalysisSamples, classes.sample,
                                                            classes.category_type, maximum_samples);
            if (presence.status != SleepSampleStatus::complete) { result.status = DaySummaryStatus::input_failed; return result; }
            has_stages = presence.has_stages;
            if (has_stages) {
                if (!statistics || !in_bed || !tracking_origin_known || !classes.source_revision || !classes.source ||
                    !classes.segment || !classes.period_builder || !classes.period) return result;
                auto input = readSleepSampleSnapshot(snapshot.sleepAnalysisSamples, classes.sample, classes.category_type,
                    classes.source_revision, classes.source, maximum_samples);
                if (!input.complete()) { result.status = DaySummaryStatus::input_failed; return result; }
                auto projection = statistics(input.non_in_bed, snapshot, context);
                if (!projection.complete()) { result.status = DaySummaryStatus::statistics_failed; return result; }
                if(admission&&!admission()){result.status=DaySummaryStatus::operation_rejected;return result;}
                NSArray *bed = in_bed(input.original_in_bed);
                if (!WFHSActuallyInheritsFrom(bed, NSArray.class)) { result.status = DaySummaryStatus::in_bed_failed; return result; }
                if(admission&&!admission()){result.status=DaySummaryStatus::operation_rejected;return result;}
                periods = makeLegacySleepPeriods(projection, bed, tracking_origin_known, contains_apple_tracking,
                    classes.segment, classes.period_builder, classes.period, maximum_samples, maximum_samples);
                if (!periods.complete()) { result.status = DaySummaryStatus::periods_failed; return result; }
                if (calendar && !snapshot.sleepScheduleSamples.count && !snapshot.sleepDurationGoalSamples.count) {
                    NSCalendar *observed = calendar(snapshot.calendarCache);
                    if (!WFHSActuallyInheritsFrom(observed, NSCalendar.class)) return result;
                    // Snapshot value before original; retaining a mutable cache
                    // calendar would make before/after comparison vacuous.
                    native_calendar = [observed copy];
                    if (!WFHSActuallyInheritsFrom(native_calendar, NSCalendar.class)) return result;
                }
            }
            WFHSBoundDayContext *current = [binding contextForBuilder:builder actualCache:snapshot.calendarCache];
            if (!current || current.generation != binding_generation || current.profile != bound_profile ||
                current.calendarCache != bound_cache) return result;
            if(admission&&!admission()){result.status=DaySummaryStatus::operation_rejected;return result;}
        } @catch (NSException *candidateException) {
            (void)candidateException; result.status = DaySummaryStatus::candidate_exception; return result;
        }
    } catch (...) { result.status = DaySummaryStatus::candidate_exception; return result; }

    // Original exceptions, including any original native processing error, must
    // escape exactly as raised. Neither ObjC nor C++ candidate catch encloses it.
    id native = original(builder);
    try {
    @try {
        if(admission&&!admission()){result.status=DaySummaryStatus::operation_rejected;return result;}
        WFHSBoundDayContext *current = [binding contextForBuilder:builder actualCache:bound_cache];
        if (!current || current.generation != binding_generation || current.profile != bound_profile ||
            current.calendarCache != bound_cache) return result;
    } @catch (NSException *candidateException) {
        (void)candidateException; result.status = DaySummaryStatus::candidate_exception; return result;
    }
    } catch (...) {result.status=DaySummaryStatus::candidate_exception;return result;}
    if (!has_stages) {
        if (native && object_getClass(native) != classes.summary) { result.status = DaySummaryStatus::output_failed; return result; }
        result.summary = native; result.status = native ? DaySummaryStatus::complete : DaySummaryStatus::native_no_summary;
        return result;
    }
    if (!native) {
        if (!native_calendar || snapshot.sleepScheduleSamples.count || snapshot.sleepDurationGoalSamples.count) {
            result.status = DaySummaryStatus::nil_original_unsupported; return result;
        }
        try {
            @try {
                NSCalendar *after = calendar(snapshot.calendarCache);
                if (!WFHSActuallyInheritsFrom(after, NSCalendar.class) || ![native_calendar isEqual:after]) {
                    result.status = DaySummaryStatus::original_context_mismatch; return result;
                }
                // Guarded exact native nil plus empty metadata input means
                // there are no filtered schedules/goal to guess or preserve.
                if (!periods.periods.count) {
                    result.status = DaySummaryStatus::native_no_summary; return result;
                }
                auto built = makeLegacyDaySummaryWithoutMetadata(snapshot.morningIndex, snapshot.dateInterval,
                    native_calendar, periods, classes.summary, classes.period, maximum_samples);
                if (!built.complete()) { result.status = DaySummaryStatus::output_failed; return result; }
                result.summary = built.summary; result.status = DaySummaryStatus::complete;
            } @catch (NSException *candidateException) {
                (void)candidateException; result.status = DaySummaryStatus::candidate_exception;
            }
        } catch (...) { result.status = DaySummaryStatus::candidate_exception; }
        return result;
    }
    @try {
        if (object_getClass(native) != classes.summary) { result.status = DaySummaryStatus::original_context_mismatch; return result; }
        id interval = [(id<WFHSDayResultContext>)native dateInterval];
        if (!WFHSActuallyInheritsFrom(interval, NSDateInterval.class) ||
            [(id<WFHSDayResultContext>)native morningIndex] != snapshot.morningIndex ||
            [interval startDate].timeIntervalSinceReferenceDate != snapshot.dateInterval.startDate.timeIntervalSinceReferenceDate ||
            [interval endDate].timeIntervalSinceReferenceDate != snapshot.dateInterval.endDate.timeIntervalSinceReferenceDate) {
            result.status = DaySummaryStatus::original_context_mismatch; return result;
        }
        auto rebuilt = rebuildLegacyDaySummary(native, periods, classes.summary, classes.period, maximum_samples);
        if (!rebuilt.complete()) { result.status = DaySummaryStatus::output_failed; return result; }
        result.summary = rebuilt.summary; result.status = DaySummaryStatus::complete;
    } @catch (NSException *candidateException) {
        (void)candidateException; result.summary = nil; result.status = DaySummaryStatus::candidate_exception;
    }
    return result;
}

id createCompatibleDaySummaryForEnumeration(id builder,id actual_cache,WFHSQueryBinding *binding,
    WFHSEnumerationFailure *failure,const DaySummaryClasses &classes,std::size_t maximum_samples,
    bool tracking_origin_known,bool contains_apple_tracking,const DayStatistics &statistics,
    const NativeInBedSegments &in_bed,const GuardedOriginalDayCreate &original,const StableDayCalendar &calendar) {
    if (!failure) return nil; // Unbound callers remain unsupported, never call original.
    if (![failure allowsCandidateForBinding:binding builder:builder actualCache:actual_cache]) return nil;
    auto attempt=createCompatibleDaySummary(builder,binding,classes,maximum_samples,
        tracking_origin_known,contains_apple_tracking,statistics,in_bed,original,calendar,
        [&](){return [failure allowsCandidateForBinding:binding builder:builder actualCache:actual_cache]==YES;});
    if (!attempt.complete()) {
        if (![failure recordCandidateFailureForBuilder:builder actualCache:actual_cache
                code:100+static_cast<NSInteger>(attempt.status)])
            [failure recordOperationProtocolFailure];
        return nil;
    }
    if (![failure allowsCandidateForBinding:binding builder:builder actualCache:actual_cache]) return nil;
    return attempt.summary;
}
} }
