#include "LegacyPeriodAdapter.hpp"
#import "RuntimeTypeChecks.h"
#include <cstring>

@protocol WFHSLegacySegment
+ (id)sleepPeriodSegmentWithDateInterval:(NSDateInterval *)interval sampleIntervals:(NSArray *)samples
    category:(NSInteger)category containsAppleSleepTrackingData:(BOOL)containsApple;
- (NSDateInterval *)dateInterval;
- (NSArray *)sampleIntervals;
- (NSInteger)category;
- (BOOL)containsAppleSleepTrackingData;
@end
@protocol WFHSLegacyPeriodBuilder
- (instancetype)init;
- (void)addOrderedSegment:(id)segment;
- (NSArray *)finish;
@end
@protocol WFHSLegacyPeriod
- (NSDateInterval *)dateInterval;
- (NSArray *)segments;
@end
@protocol WFHSLegacyDaySummary
- (NSInteger)morningIndex;
- (NSDateInterval *)dateInterval;
- (NSCalendar *)calendar;
- (NSArray *)schedules;
- (id)sleepDurationGoal;
- (NSArray *)periods;
+ (id)daySummaryWithMorningIndex:(NSInteger)index dateInterval:(NSDateInterval *)interval
    calendar:(NSCalendar *)calendar periods:(NSArray *)periods schedules:(NSArray *)schedules sleepDurationGoal:(id)goal;
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
bool finiteInterval(id interval) {
    if (!WFHSActuallyInheritsFrom(interval, NSDateInterval.class)) return false;
    id start = [interval startDate], end = [interval endDate];
    if (!WFHSActuallyInheritsFrom(start, NSDate.class) || !WFHSActuallyInheritsFrom(end, NSDate.class)) return false;
    const double s = [start timeIntervalSinceReferenceDate], e = [end timeIntervalSinceReferenceDate];
    return std::isfinite(s) && std::isfinite(e) && e > s && std::isfinite(e - s);
}
bool sameInterval(id interval, double start, double end) {
    return finiteInterval(interval) && [[interval startDate] timeIntervalSinceReferenceDate] == start &&
        [[interval endDate] timeIntervalSinceReferenceDate] == end;
}
NSDateInterval *dateInterval(double start, double end) {
    return [[NSDateInterval alloc] initWithStartDate:[NSDate dateWithTimeIntervalSinceReferenceDate:start]
                                           endDate:[NSDate dateWithTimeIntervalSinceReferenceDate:end]];
}
}

LegacyPeriodAttempt makeLegacySleepPeriods(const LegacyProjection &projection,
    NSArray *native_in_bed_segments, bool apple_tracking_origin_known, bool contains_apple_tracking,
    Class segment_class, Class period_builder_class, Class period_class,
    std::size_t maximum_segments, std::size_t maximum_sample_intervals) {
    LegacyPeriodAttempt result;
    if (!maximum_segments || !maximum_sample_intervals) {
        result.status = LegacyPeriodStatus::invalid_configuration; return result;
    }
    if (!projection.complete()) { result.status = LegacyPeriodStatus::invalid_projection; return result; }
    if (!apple_tracking_origin_known || !segment_class || !period_builder_class || !period_class) return result;
    try {
        @try {
            if (!declaredABI(object_getClass(segment_class),
                    @selector(sleepPeriodSegmentWithDateInterval:sampleIntervals:category:containsAppleSleepTrackingData:),
                    "@44@0:8@16@24q32B40") ||
                !declaredABI(segment_class, @selector(dateInterval), "@16@0:8") ||
                !declaredABI(segment_class, @selector(sampleIntervals), "@16@0:8") ||
                !declaredABI(segment_class, @selector(category), "q16@0:8") ||
                !declaredABI(segment_class, @selector(containsAppleSleepTrackingData), "B16@0:8") ||
                !declaredABI(period_builder_class, @selector(init), "@16@0:8") ||
                !declaredABI(period_builder_class, @selector(addOrderedSegment:), "v24@0:8@16") ||
                !declaredABI(period_builder_class, @selector(finish), "@16@0:8") ||
                !declaredABI(period_class, @selector(segments), "@16@0:8") ||
                !declaredABI(period_class, @selector(dateInterval), "@16@0:8")) return result;
            const auto &segments = projection.data()->asleep_segments;
            if (!WFHSActuallyInheritsFrom(native_in_bed_segments, NSArray.class) ||
                segments.size() > maximum_segments || native_in_bed_segments.count > maximum_segments - segments.size()) {
                result.status = LegacyPeriodStatus::invalid_configuration; return result;
            }
            NSMutableArray *all = [NSMutableArray arrayWithCapacity:segments.size() + native_in_bed_segments.count];
            if (!all) { result.status = LegacyPeriodStatus::allocation_failure; return result; }
            std::size_t remaining = maximum_sample_intervals;
            for (id segment in native_in_bed_segments) {
                if (object_getClass(segment) != segment_class || [(id<WFHSLegacySegment>)segment category] != 0 ||
                    !finiteInterval([(id<WFHSLegacySegment>)segment dateInterval])) {
                    result.status = LegacyPeriodStatus::invalid_native_result; return result;
                }
                id parts = [(id<WFHSLegacySegment>)segment sampleIntervals];
                if (!WFHSActuallyInheritsFrom(parts, NSArray.class) || [parts count] > remaining) {
                    result.status = LegacyPeriodStatus::invalid_native_result; return result;
                }
                remaining -= [parts count];
                for (id part in parts) if (!finiteInterval(part)) {
                    result.status = LegacyPeriodStatus::invalid_native_result; return result;
                }
                [all addObject:segment];
            }
            for (const auto &segment : segments) {
                if (segment.sample_intervals.empty() || segment.sample_intervals.size() > remaining) {
                    result.status = LegacyPeriodStatus::invalid_configuration; return result;
                }
                remaining -= segment.sample_intervals.size();
                NSDateInterval *envelope = dateInterval(segment.start, segment.end);
                NSMutableArray *samples = [NSMutableArray arrayWithCapacity:segment.sample_intervals.size()];
                if (!envelope || !samples) { result.status = LegacyPeriodStatus::allocation_failure; return result; }
                for (const auto &interval : segment.sample_intervals) {
                    NSDateInterval *part = dateInterval(interval.start, interval.end);
                    if (!part) { result.status = LegacyPeriodStatus::allocation_failure; return result; }
                    [samples addObject:part];
                }
                id native = [(id<WFHSLegacySegment>)segment_class sleepPeriodSegmentWithDateInterval:envelope
                    sampleIntervals:samples category:1 containsAppleSleepTrackingData:contains_apple_tracking];
                if (object_getClass(native) != segment_class || [(id<WFHSLegacySegment>)native category] != 1 ||
                    !![(id<WFHSLegacySegment>)native containsAppleSleepTrackingData] != contains_apple_tracking) {
                    result.status = LegacyPeriodStatus::invalid_native_result; return result;
                }
                id nativeEnvelope = [(id<WFHSLegacySegment>)native dateInterval];
                id nativeParts = [(id<WFHSLegacySegment>)native sampleIntervals];
                if (!sameInterval(nativeEnvelope, segment.start, segment.end) ||
                    !WFHSActuallyInheritsFrom(nativeParts, NSArray.class) ||
                    [nativeParts count] != segment.sample_intervals.size()) {
                    result.status = LegacyPeriodStatus::invalid_native_result; return result;
                }
                for (std::size_t i = 0; i < segment.sample_intervals.size(); ++i) {
                    const auto &part = segment.sample_intervals[i];
                    if (!sameInterval(nativeParts[i], part.start, part.end)) {
                        result.status = LegacyPeriodStatus::invalid_native_result; return result;
                    }
                }
                [all addObject:native];
            }
            if (!all.count) {
                // Audited 15.4 finish flushes even an empty builder, creating a
                // nil-start NSDateInterval. Never call it for empty scratch.
                result.periods = @[]; result.status = LegacyPeriodStatus::complete; return result;
            }
            [all sortUsingComparator:^NSComparisonResult(id a, id b) {
                return [[[(id<WFHSLegacySegment>)a dateInterval] startDate]
                    compare:[[(id<WFHSLegacySegment>)b dateInterval] startDate]];
            }];
            id allocated = [period_builder_class alloc];
            if (object_getClass(allocated) != period_builder_class) return result;
            id builder = [(id<WFHSLegacyPeriodBuilder>)allocated init];
            if (object_getClass(builder) != period_builder_class) return result;
            for (id segment in all) [(id<WFHSLegacyPeriodBuilder>)builder addOrderedSegment:segment];
            id periods = [(id<WFHSLegacyPeriodBuilder>)builder finish];
            if (!WFHSActuallyInheritsFrom(periods, NSArray.class) || ![periods count] || [periods count] > all.count) {
                result.status = LegacyPeriodStatus::invalid_native_result; return result;
            }
            NSArray *snapshot = [[NSArray alloc] initWithArray:periods];
            if (!snapshot || snapshot.count != [periods count]) {
                result.status = LegacyPeriodStatus::allocation_failure; return result;
            }
            NSUInteger cursor = 0;
            for (id period in snapshot) {
                if (object_getClass(period) != period_class) {
                    result.status = LegacyPeriodStatus::invalid_native_result; return result;
                }
                id members = [(id<WFHSLegacyPeriod>)period segments];
                if (!WFHSActuallyInheritsFrom(members, NSArray.class) || ![members count] ||
                    [members count] > all.count - cursor) {
                    result.status = LegacyPeriodStatus::invalid_native_result; return result;
                }
                double minimum = 0, maximum = 0; bool first = true;
                for (id member in members) {
                    if (member != all[cursor++]) {
                        result.status = LegacyPeriodStatus::invalid_native_result; return result;
                    }
                    id interval = [(id<WFHSLegacySegment>)member dateInterval];
                    if (!finiteInterval(interval)) {
                        result.status = LegacyPeriodStatus::invalid_native_result; return result;
                    }
                    const double start = [[interval startDate] timeIntervalSinceReferenceDate];
                    const double end = [[interval endDate] timeIntervalSinceReferenceDate];
                    minimum = first ? start : std::min(minimum, start);
                    maximum = first ? end : std::max(maximum, end); first = false;
                }
                if (!sameInterval([(id<WFHSLegacyPeriod>)period dateInterval], minimum, maximum)) {
                    result.status = LegacyPeriodStatus::invalid_native_result; return result;
                }
            }
            if (cursor != all.count) { result.status = LegacyPeriodStatus::invalid_native_result; return result; }
            result.periods = snapshot;
            result.status = LegacyPeriodStatus::complete;
        } @catch (NSException *candidateException) {
            (void)candidateException;
            result.periods = nil; result.status = LegacyPeriodStatus::candidate_exception;
        }
    } catch (const std::bad_alloc &) { result.periods = nil; result.status = LegacyPeriodStatus::allocation_failure; }
    catch (const std::length_error &) { result.periods = nil; result.status = LegacyPeriodStatus::allocation_failure; }
    return result;
}

bool hasLegacyDaySummaryABI(Class summary_class) {
    if (!summary_class) return false;
    return declaredABI(object_getClass(summary_class),
        @selector(daySummaryWithMorningIndex:dateInterval:calendar:periods:schedules:sleepDurationGoal:),
        "@64@0:8q16@24@32@40@48@56") &&
        declaredABI(summary_class, @selector(morningIndex), "q16@0:8") &&
        declaredABI(summary_class, @selector(dateInterval), "@16@0:8") &&
        declaredABI(summary_class, @selector(calendar), "@16@0:8") &&
        declaredABI(summary_class, @selector(schedules), "@16@0:8") &&
        declaredABI(summary_class, @selector(sleepDurationGoal), "@16@0:8") &&
        declaredABI(summary_class, @selector(periods), "@16@0:8");
}

LegacyDaySummaryAttempt rebuildLegacyDaySummary(id original_summary, const LegacyPeriodAttempt &periods,
    Class summary_class, Class period_class, std::size_t maximum_periods) {
    LegacyDaySummaryAttempt result;
    if (!maximum_periods) { result.status = LegacyPeriodStatus::invalid_configuration; return result; }
    if (!summary_class || !period_class || object_getClass(original_summary) != summary_class || !periods.complete()) return result;
    @try {
        if (!declaredABI(object_getClass(summary_class),
                @selector(daySummaryWithMorningIndex:dateInterval:calendar:periods:schedules:sleepDurationGoal:),
                "@64@0:8q16@24@32@40@48@56") ||
            !declaredABI(summary_class, @selector(morningIndex), "q16@0:8") ||
            !declaredABI(summary_class, @selector(dateInterval), "@16@0:8") ||
            !declaredABI(summary_class, @selector(calendar), "@16@0:8") ||
            !declaredABI(summary_class, @selector(schedules), "@16@0:8") ||
            !declaredABI(summary_class, @selector(sleepDurationGoal), "@16@0:8") ||
            !declaredABI(summary_class, @selector(periods), "@16@0:8")) return result;
        if (!WFHSActuallyInheritsFrom(periods.periods, NSArray.class) || periods.periods.count > maximum_periods) {
            result.status = LegacyPeriodStatus::invalid_configuration; return result;
        }
        for (id period in periods.periods) if (object_getClass(period) != period_class) {
            result.status = LegacyPeriodStatus::invalid_native_result; return result;
        }
        id<WFHSLegacyDaySummary> original = original_summary;
        NSDateInterval *interval = [original dateInterval];
        NSCalendar *calendar = [original calendar];
        NSArray *schedules = [original schedules];
        id goal = [original sleepDurationGoal];
        NSInteger index = [original morningIndex];
        if (!finiteInterval(interval) || !WFHSActuallyInheritsFrom(calendar, NSCalendar.class) ||
            !WFHSActuallyInheritsFrom(schedules, NSArray.class)) {
            result.status = LegacyPeriodStatus::invalid_native_result; return result;
        }
        id created = [(id<WFHSLegacyDaySummary>)summary_class daySummaryWithMorningIndex:index dateInterval:interval
            calendar:calendar periods:periods.periods schedules:schedules sleepDurationGoal:goal];
        if (object_getClass(created) != summary_class || created == original_summary) {
            result.status = LegacyPeriodStatus::invalid_native_result; return result;
        }
        id<WFHSLegacyDaySummary> replacement = created;
        id returnedPeriods = [replacement periods];
        id returnedSchedules = [replacement schedules];
        id returnedCalendar = [replacement calendar];
        id returnedGoal = [replacement sleepDurationGoal];
        // The audited native factory stores/copies immutable containers. Verify
        // content by identity, not overridable isEqual: or regenerated schedules.
        // Native factory sends copy to calendar and goal too. Pointer equality
        // would reject valid NSCalendar copies. Value equality here relies on
        // the independently audited Foundation/goal implementation, not on the
        // untrusted returned object claiming isEqual: itself.
        if ([replacement morningIndex] != index || !WFHSActuallyInheritsFrom(returnedCalendar, NSCalendar.class) ||
            ![calendar isEqual:returnedCalendar] ||
            (returnedGoal != goal && (!goal || ![goal isEqual:returnedGoal])) ||
            !sameInterval([replacement dateInterval], interval.startDate.timeIntervalSinceReferenceDate,
                          interval.endDate.timeIntervalSinceReferenceDate) ||
            !WFHSActuallyInheritsFrom(returnedPeriods, NSArray.class) || [returnedPeriods count] != periods.periods.count ||
            !WFHSActuallyInheritsFrom(returnedSchedules, NSArray.class) || [returnedSchedules count] != schedules.count) {
            result.status = LegacyPeriodStatus::invalid_native_result; return result;
        }
        for (NSUInteger i = 0; i < periods.periods.count; ++i) if (returnedPeriods[i] != periods.periods[i]) {
            result.status = LegacyPeriodStatus::invalid_native_result; return result;
        }
        for (NSUInteger i = 0; i < schedules.count; ++i) if (returnedSchedules[i] != schedules[i]) {
            result.status = LegacyPeriodStatus::invalid_native_result; return result;
        }
        result.summary = created; result.status = LegacyPeriodStatus::complete;
    } @catch (NSException *candidateException) {
        (void)candidateException; result.summary = nil; result.status = LegacyPeriodStatus::candidate_exception;
    }
    return result;
}

LegacyDaySummaryAttempt makeLegacyDaySummaryWithMetadata(NSInteger morning_index,
    NSDateInterval *original_day_interval, NSCalendar *stable_native_calendar,
    const LegacyPeriodAttempt &periods, NSArray *schedules, id sleep_duration_goal,
    Class summary_class, Class period_class, std::size_t maximum_periods) {
    LegacyDaySummaryAttempt result;
    if (!maximum_periods || !summary_class || !period_class || !periods.complete() ||
        !periods.periods.count) return result;
    if (!WFHSActuallyInheritsFrom(schedules, NSArray.class) ||
        schedules.count > maximum_periods) {
        result.status = LegacyPeriodStatus::invalid_configuration; return result;
    }
    @try {
        if (!finiteInterval(original_day_interval) || !WFHSActuallyInheritsFrom(stable_native_calendar, NSCalendar.class) ||
            periods.periods.count > maximum_periods ||
            !declaredABI(object_getClass(summary_class),
                @selector(daySummaryWithMorningIndex:dateInterval:calendar:periods:schedules:sleepDurationGoal:),
                "@64@0:8q16@24@32@40@48@56")) return result;
        for (SEL selector : {@selector(morningIndex), @selector(dateInterval), @selector(calendar),
                             @selector(periods), @selector(schedules), @selector(sleepDurationGoal)}) {
            if (!declaredABI(summary_class, selector, sel_isEqual(selector, @selector(morningIndex)) ? "q16@0:8" : "@16@0:8")) return result;
        }
        for (id period in periods.periods) if (object_getClass(period) != period_class) return result;
        id value = [(id<WFHSLegacyDaySummary>)summary_class daySummaryWithMorningIndex:morning_index
            dateInterval:original_day_interval calendar:stable_native_calendar periods:periods.periods
            schedules:schedules sleepDurationGoal:sleep_duration_goal];
        if (object_getClass(value) != summary_class) { result.status = LegacyPeriodStatus::invalid_native_result; return result; }
        id<WFHSLegacyDaySummary> summary = value;
        id calendar = [summary calendar], returnedSchedules = [summary schedules],
           goal = [summary sleepDurationGoal], returned = [summary periods];
        // The factory stores copies of immutable containers; verify content by
        // element identity and only fall back to isEqual: for the scalar goal.
        if ([summary morningIndex] != morning_index ||
            !sameInterval([summary dateInterval], original_day_interval.startDate.timeIntervalSinceReferenceDate,
                          original_day_interval.endDate.timeIntervalSinceReferenceDate) ||
            !WFHSActuallyInheritsFrom(calendar, NSCalendar.class) || ![stable_native_calendar isEqual:calendar] ||
            !WFHSActuallyInheritsFrom(returnedSchedules, NSArray.class) ||
            [returnedSchedules count] != schedules.count ||
            (goal != sleep_duration_goal &&
             (sleep_duration_goal == nil || ![sleep_duration_goal isEqual:goal])) ||
            !WFHSActuallyInheritsFrom(returned, NSArray.class) || [returned count] != periods.periods.count) {
            result.status = LegacyPeriodStatus::invalid_native_result; return result;
        }
        for (NSUInteger i=0; i<schedules.count; ++i) if (returnedSchedules[i] != schedules[i]) {
            result.status = LegacyPeriodStatus::invalid_native_result; return result;
        }
        for (NSUInteger i=0; i<periods.periods.count; ++i) if (returned[i] != periods.periods[i]) {
            result.status = LegacyPeriodStatus::invalid_native_result; return result;
        }
        result.summary = value; result.status = LegacyPeriodStatus::complete;
    } @catch (NSException *candidateException) {
        (void)candidateException; result.status = LegacyPeriodStatus::candidate_exception;
    }
    return result;
}

LegacyDaySummaryAttempt makeLegacyDaySummaryWithoutMetadata(NSInteger morning_index,
    NSDateInterval *original_day_interval, NSCalendar *stable_native_calendar,
    const LegacyPeriodAttempt &periods, Class summary_class, Class period_class, std::size_t maximum_periods) {
    LegacyDaySummaryAttempt result;
    if (!maximum_periods || !summary_class || !period_class || !periods.complete() || !periods.periods.count) return result;
    @try {
        if (!finiteInterval(original_day_interval) || !WFHSActuallyInheritsFrom(stable_native_calendar, NSCalendar.class) ||
            periods.periods.count > maximum_periods ||
            !declaredABI(object_getClass(summary_class),
                @selector(daySummaryWithMorningIndex:dateInterval:calendar:periods:schedules:sleepDurationGoal:),
                "@64@0:8q16@24@32@40@48@56")) return result;
        for (SEL selector : {@selector(morningIndex), @selector(dateInterval), @selector(calendar),
                             @selector(periods), @selector(schedules), @selector(sleepDurationGoal)}) {
            if (!declaredABI(summary_class, selector, sel_isEqual(selector, @selector(morningIndex)) ? "q16@0:8" : "@16@0:8")) return result;
        }
        for (id period in periods.periods) if (object_getClass(period) != period_class) return result;
        id value = [(id<WFHSLegacyDaySummary>)summary_class daySummaryWithMorningIndex:morning_index
            dateInterval:original_day_interval calendar:stable_native_calendar periods:periods.periods
            schedules:@[] sleepDurationGoal:nil];
        if (object_getClass(value) != summary_class) { result.status = LegacyPeriodStatus::invalid_native_result; return result; }
        id<WFHSLegacyDaySummary> summary = value;
        id calendar = [summary calendar], schedules = [summary schedules], returned = [summary periods];
        if ([summary morningIndex] != morning_index ||
            !sameInterval([summary dateInterval], original_day_interval.startDate.timeIntervalSinceReferenceDate,
                          original_day_interval.endDate.timeIntervalSinceReferenceDate) ||
            !WFHSActuallyInheritsFrom(calendar, NSCalendar.class) || ![stable_native_calendar isEqual:calendar] ||
            !WFHSActuallyInheritsFrom(schedules, NSArray.class) || [schedules count] || [summary sleepDurationGoal] ||
            !WFHSActuallyInheritsFrom(returned, NSArray.class) || [returned count] != periods.periods.count) {
            result.status = LegacyPeriodStatus::invalid_native_result; return result;
        }
        for (NSUInteger i=0; i<periods.periods.count; ++i) if (returned[i] != periods.periods[i]) {
            result.status = LegacyPeriodStatus::invalid_native_result; return result;
        }
        result.summary = value; result.status = LegacyPeriodStatus::complete;
    } @catch (NSException *candidateException) {
        (void)candidateException; result.status = LegacyPeriodStatus::candidate_exception;
    }
    return result;
}
} }
