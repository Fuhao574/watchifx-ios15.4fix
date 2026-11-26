// Derived statistics -> existing iOS15.4 segment/period objects. No samples,
// persistence, original day-builder invocation, class discovery or runtime hook.
#ifndef WFHS_LEGACY_PERIOD_ADAPTER_HPP
#define WFHS_LEGACY_PERIOD_ADAPTER_HPP
#import <Foundation/Foundation.h>
#include "LegacyDerivedSummary.hpp"

namespace watchfix { namespace healthsupport {
enum class LegacyPeriodStatus {
    unverified,
    complete,
    invalid_configuration,
    invalid_projection,
    invalid_native_result,
    candidate_exception,
    allocation_failure
};
struct LegacyPeriodAttempt {
    LegacyPeriodStatus status = LegacyPeriodStatus::unverified;
    // nil on failure; complete empty array is intentional no periods. Does not
    // decide whether a native day summary should be emitted for schedules/goal.
    __strong NSArray *periods = nil;
    bool complete() const noexcept { return status == LegacyPeriodStatus::complete && periods != nil; }
};

// Classes must first pass exact-build/image/owner/IMP/stability verification.
// Existing InBed segments come from the unchanged native InBed path, NOT raw
// category0 samples. Apple tracking flag requires a separately audited origin;
// false is not a fallback for an unknown source. This adapter does not derive it.
// Fresh period builder is private scratch and discarded after this call.
// maximum_sample_intervals covers both unchanged InBed and derived Asleep.
LegacyPeriodAttempt makeLegacySleepPeriods(const LegacyProjection &projection,
    NSArray *native_in_bed_segments, bool apple_tracking_origin_known, bool contains_apple_tracking,
    Class segment_class, Class period_builder_class, Class period_class,
    std::size_t maximum_segments = 100000, std::size_t maximum_sample_intervals = 100000);

struct LegacyDaySummaryAttempt {
    LegacyPeriodStatus status = LegacyPeriodStatus::unverified;
    __strong id summary = nil;
    bool complete() const noexcept { return status == LegacyPeriodStatus::complete && summary != nil; }
};
// Metadata-only ABI preflight, before any summary getter/factory invocation.
// This is not image/owner/IMP verification or class discovery.
bool hasLegacyDaySummaryABI(Class summary_class);
// Preserve ORIGINAL native metadata filtering, calendar, interval and goal.
// Original create may only have been run after its empty-period hazard is
// independently guarded. This API neither invokes nor makes original safe.
// nil original remains unsupported, not manufactured context or empty success.
LegacyDaySummaryAttempt rebuildLegacyDaySummary(id original_summary, const LegacyPeriodAttempt &periods,
    Class summary_class, Class period_class, std::size_t maximum_periods = 100000);

// Narrow stage-only original-nil route: caller has independently established
// exact guarded native create returned nil normally AND BOTH schedule and goal
// INPUT arrays were empty. No native metadata was dropped or reconstructed.
// interval is the original init-stored interval; calendar must be the audited
// stable calendarCache result, not a default calendar or guessed UTC replacement.
// Same factory, but forwards metadata the audited builder already held for this
// day instead of an empty placeholder. This module never chooses among several
// goal samples: the caller must pass the single object it verified. Rejects a
// returned summary whose schedules/goal differ from what was supplied.
LegacyDaySummaryAttempt makeLegacyDaySummaryWithMetadata(NSInteger morning_index,
    NSDateInterval *original_day_interval, NSCalendar *stable_native_calendar,
    const LegacyPeriodAttempt &periods, NSArray *schedules, id sleep_duration_goal,
    Class summary_class, Class period_class, std::size_t maximum_periods = 100000);

LegacyDaySummaryAttempt makeLegacyDaySummaryWithoutMetadata(NSInteger morning_index,
    NSDateInterval *original_day_interval, NSCalendar *stable_native_calendar,
    const LegacyPeriodAttempt &periods, Class summary_class, Class period_class,
    std::size_t maximum_periods = 100000);
} }
#endif
