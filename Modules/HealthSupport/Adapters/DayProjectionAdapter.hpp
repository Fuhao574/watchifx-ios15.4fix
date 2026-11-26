// Stage-aware replacement for the audited 15.4 day summary construction.
//
// This adapter does NOT call the original -createDaySummary. On a day that
// holds raw Core/Deep/REM values the native builder produces zero segments and
// its period finish reads an unset start date, so the original must be skipped
// rather than wrapped. The caller decides what to do with each status:
//
//   complete              -> return summary
//   no_stages             -> call the previous implementation (native day)
//   anything else         -> return nil; never call the previous implementation
//
// No hook, class discovery, persistence or sample mutation lives here. All
// classes and the builder object must come from an independently verified
// exact-build bootstrap.
#ifndef WFHS_DAY_PROJECTION_ADAPTER_HPP
#define WFHS_DAY_PROJECTION_ADAPTER_HPP

#import <Foundation/Foundation.h>
#include "LegacyPeriodAdapter.hpp"
#include "SleepSampleAdapter.hpp"
#include "SleepSliceCompetition.hpp"

#include <cstddef>

namespace watchfix { namespace healthsupport {

enum class DayProjectionStatus {
    unverified,
    complete,
    no_stages,
    invalid_configuration,
    snapshot_failed,
    input_failed,
    statistics_failed,
    in_bed_failed,
    periods_failed,
    metadata_invalid,
    output_failed,
    resource_limit,
    candidate_exception
};

struct DayProjectionClasses {
    Class builder = Nil;           // HDSleepDaySummaryBuilder
    Class calendar_cache = Nil;    // HKCalendarCache
    Class sample = Nil;            // HKCategorySample
    Class category_type = Nil;     // HKCategoryType
    Class source_revision = Nil;   // HKSourceRevision
    Class source = Nil;            // HKSource
    Class segment = Nil;           // HKSleepPeriodSegment
    Class period_builder = Nil;    // HDSleepPeriodArrayBuilder
    Class period = Nil;            // HKSleepPeriod
    Class summary = Nil;           // HKSleepDaySummary
    Class segment_builder = Nil;   // HDSleepPeriodSegmentArrayBuilder
};

struct DayProjectionAttempt {
    DayProjectionStatus status = DayProjectionStatus::unverified;
    __strong id summary = nil;
    bool has_stages = false;
    // True when overlapping fragments were resolved slice by slice. The input
    // was then not verbatim, so reports must not call it native-equivalent.
    bool resolved_overlap = false;
    // True when returning to the previous createDaySummary cannot expose a
    // stage-only day: either no stage value was observed, or the builder could
    // not be read at all and this module therefore changed nothing.
    bool native_fallback_safe = true;
    bool complete() const noexcept {
        return status == DayProjectionStatus::complete && summary != nil;
    }
};

// maximum_samples bounds the snapshot and sample read; maximum_segments bounds
// derived segments and InBed sample intervals. Both must be non-zero.
DayProjectionAttempt projectSleepDaySummary(id builder, const DayProjectionClasses &classes,
    std::size_t maximum_samples = 100000, std::size_t maximum_segments = 100000);

} }
#endif
