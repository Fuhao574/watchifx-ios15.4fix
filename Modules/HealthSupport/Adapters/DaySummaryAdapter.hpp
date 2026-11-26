// Actual day-builder context + checked non-InBed statistics -> legacy summary.
// Still offline. Does not install hooks, call enumerate or modify Health samples.
#ifndef WFHS_DAY_SUMMARY_ADAPTER_HPP
#define WFHS_DAY_SUMMARY_ADAPTER_HPP
#import "DayBuilderSnapshot.h"
#import "QueryBuilderBinding.h"
#import "EnumerationAdapter.h"
#include "LegacyPeriodAdapter.hpp"
#include "SleepSampleAdapter.hpp"
#include <functional>

namespace watchfix { namespace healthsupport {
enum class DaySummaryStatus {
    unverified, complete, native_no_summary, snapshot_failed, input_failed,
    statistics_failed, in_bed_failed, periods_failed, original_context_mismatch,
    nil_original_unsupported, output_failed, candidate_exception, operation_rejected
};
struct DaySummaryAttempt {
    DaySummaryStatus status = DaySummaryStatus::unverified;
    __strong id summary = nil;
    // Only complete or native_no_summary are successful. nil on other states
    // MUST become explicit query failure, not the original native skip-nil path.
    bool complete() const noexcept { return status == DaySummaryStatus::complete || status == DaySummaryStatus::native_no_summary; }
};
struct DaySummaryClasses {
    Class builder = Nil, calendar_cache = Nil, sample = Nil, category_type = Nil;
    Class source_revision = Nil, source = Nil, segment = Nil, period_builder = Nil, period = Nil, summary = Nil;
};
using DayStatistics = std::function<LegacyProjection(const std::vector<StageFragment> &, WFHSDaySnapshot *, WFHSBoundDayContext *)>;
using NativeInBedSegments = std::function<NSArray *(NSArray *)>;
using GuardedOriginalDayCreate = std::function<id(id)>;
// Synchronous revalidation at callback boundaries and immediately before original.
// Does not cancel work already running or supply native exclusivity.
using DayCreateAdmission = std::function<bool()>;
// Optional exact cache method adapter. Provider must independently guarantee
// stable native calendar over the WHOLE operation, not just equality of two
// observations. Empty callback keeps the original-nil route unsupported.
using StableDayCalendar = std::function<NSCalendar *(id)>;

// Statistics is supplied with the actual bound profile/cache and original day
// interval; it must return a checked FULL stage competition result, not raw union.
// Original callback may only call native create after exact period empty guard
// is installed and checked on its actual builder. This adapter CANNOT prove that
// by receiving a std::function. No runtime caller supplies that proof yet.
// Stats/period candidate work completes BEFORE original. Original then executes
// once preserving schedule/goal filtering, and rebuild reuses its real metadata.
// Unknown failure never falls back to unsafe original or silent empty success.
// Original-nil may be built only when both metadata INPUT arrays are empty and
// an independently stable native calendar callback was supplied. Other nil
// contexts stay unsupported. Checked projection is not itself proof that the
// statistics closure used this day/profile's audited complete bucket collection.
DaySummaryAttempt createCompatibleDaySummary(id builder, WFHSQueryBinding *binding,
    const DaySummaryClasses &classes, std::size_t maximum_samples,
    bool tracking_origin_known, bool contains_apple_tracking,
    const DayStatistics &statistics, const NativeInBedSegments &in_bed,
    const GuardedOriginalDayCreate &original, const StableDayCalendar &calendar = {},
    const DayCreateAdmission &admission = {});

// Explicit join to this enumeration's failure channel. No current-query lookup
// or TLS. Caller must provide the matching actual cache from verified snapshot.
// Successful native_no_summary remains nil; every candidate failure is latched
// before returning nil to the original enumerator's internal skip path.
// Checks failure/binding/builder/cache/generation BEFORE candidate/original work
// and again before publishing. Prior operation failure blocks subsequent work;
// no cross-thread permission or rollback of earlier callbacks is implied.
id createCompatibleDaySummaryForEnumeration(id builder, id actual_cache, WFHSQueryBinding *binding,
    WFHSEnumerationFailure *failure, const DaySummaryClasses &classes, std::size_t maximum_samples,
    bool tracking_origin_known, bool contains_apple_tracking, const DayStatistics &statistics,
    const NativeInBedSegments &in_bed, const GuardedOriginalDayCreate &original,
    const StableDayCalendar &calendar = {});
} }
#endif
