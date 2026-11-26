// Audited iOS16 MULTI-SAMPLE source-merge advance formula only. Not the complete
// source pipeline, not a statistics bucket builder, and not a calendar API.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_SOURCE_MERGE_ADVANCE_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_SOURCE_MERGE_ADVANCE_HPP

#include "NumericPolicy.hpp"

#include <algorithm>
#include <cmath>

namespace watchfix { namespace healthsupport {

enum class SourceAdvanceStatus {
    complete,
    invalid_input,
    nonfinite_arithmetic,
    no_representable_progress,
    nonfinite_advance_duration
};

struct SourceAdvanceData { double next; };
class SourceAdvanceResult;
SourceAdvanceResult nextMultiSampleSourceMergeTime(double, double, double) noexcept;

class SourceAdvanceResult {
public:
    SourceAdvanceStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == SourceAdvanceStatus::complete; }
    const SourceAdvanceData *data() const noexcept { return complete() ? &data_ : nullptr; }
private:
    SourceAdvanceStatus status_ = SourceAdvanceStatus::invalid_input;
    SourceAdvanceData data_{0};
    friend SourceAdvanceResult nextMultiSampleSourceMergeTime(double, double, double) noexcept;
};

// event_time is the already-selected native event candidate, not necessarily the
// query target. No target clamp is invented: next MAY exceed event_time AND
// target (audited example current31,event/target45,g30 -> next60).
// Coordinates are timeIntervalSinceReferenceDate; the grid origin is numerical0,
// not the sleep-day/calendar anchor. g==0/negative/unknown follows no path here.
inline SourceAdvanceResult nextMultiSampleSourceMergeTime(double current, double event_time,
                                                           double granularity) noexcept {
    SourceAdvanceResult result;
    if (!std::isfinite(current) || !std::isfinite(event_time) || !std::isfinite(granularity) ||
        granularity <= 0 || event_time <= current) return result;
    const double following = current + granularity;
    const double event_units = event_time / granularity;
    const double following_units = following / granularity;
    if (!std::isfinite(following) || !std::isfinite(event_units) || !std::isfinite(following_units)) {
        result.status_ = SourceAdvanceStatus::nonfinite_arithmetic;
        return result;
    }
    const double event_grid = granularity * std::floor(event_units);
    const double next_grid = granularity * std::floor(following_units);
    if (!std::isfinite(event_grid) || !std::isfinite(next_grid)) {
        result.status_ = SourceAdvanceStatus::nonfinite_arithmetic;
        return result;
    }
    const double next = std::max(event_grid, next_grid);
    // Native may have additional caller constraints. Fail explicitly instead of
    // turning a numerical no-progress case into a loop or using nextafter/clamp
    // that would silently change the audited formula.
    if (!(next > current)) {
        result.status_ = SourceAdvanceStatus::no_representable_progress;
        return result;
    }
    // This module feeds duration-based splitting/statistics. Finite endpoints
    // alone are not sufficient when subtracting across the double range would
    // overflow. Reject, without changing the audited coordinate formula.
    if (!std::isfinite(next - current)) {
        result.status_ = SourceAdvanceStatus::nonfinite_advance_duration;
        return result;
    }
    result.data_.next = next;
    result.status_ = SourceAdvanceStatus::complete;
    return result;
}

} }
#endif
