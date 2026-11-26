// Post-statistics projection only. DO NOT feed raw samples or erase Awake before
// source selection and stage competition. No HealthKit, persistence or hooks.
#ifndef WATCHFIX_HEALTH_SUPPORT_LEGACY_DERIVED_SUMMARY_HPP
#define WATCHFIX_HEALTH_SUPPORT_LEGACY_DERIVED_SUMMARY_HPP

#include "NumericPolicy.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <new>
#include <stdexcept>
#include <utility>
#include <vector>

namespace watchfix { namespace healthsupport {

enum class StatisticsInputState {
    unresolved_raw_samples,
    resolved_statistics_intervals
};

// An already source-resolved, non-overlapping category output interval, not an
// HKCategorySample. InBed is produced separately by the native path and is not
// accepted by this non-InBed statistics projection function.
struct StageStatisticsInterval {
    std::int64_t category;
    double start;
    double end;
};

struct TimeInterval { double start; double end; };

struct LegacyAsleepSegment {
    // category1 describes this DERIVED segment only. No raw input is rewritten.
    std::int64_t category = 1;
    double start = 0;
    double end = 0;
    std::vector<TimeInterval> sample_intervals;
};

enum class ProjectionStatus {
    complete,
    unresolved_statistics,
    invalid_configuration,
    input_limit,
    invalid_category,
    invalid_interval,
    unordered_or_overlapping_statistics,
    invalid_accumulated_duration,
    invalid_bounding_span,
    allocation_failure
};

struct LegacyProjectionData {
    std::vector<LegacyAsleepSegment> asleep_segments;
    double asleep_duration = 0;
};

struct ProjectionConfiguration;
class LegacyProjection;
LegacyProjection projectLegacySleepSummary(const std::vector<StageStatisticsInterval> &,
                                           StatisticsInputState, ProjectionConfiguration);

class LegacyProjection {
public:
    ProjectionStatus status() const noexcept { return status_; }
    bool complete() const noexcept { return status_ == ProjectionStatus::complete; }
    // No failure payload is exposed as a normal zero/empty summary. A complete
    // empty result has NONNULL data, unlike any failure. Future native adapter
    // must route nullptr to explicit query failure, not normal no-data.
    const LegacyProjectionData *data() const noexcept { return complete() ? &data_ : nullptr; }
private:
    ProjectionStatus status_ = ProjectionStatus::unresolved_statistics;
    LegacyProjectionData data_;
    friend LegacyProjection projectLegacySleepSummary(const std::vector<StageStatisticsInterval> &,
                                                       StatisticsInputState, ProjectionConfiguration);
};

struct ProjectionConfiguration {
    // Audited native16 post-statistics combination default. This is independent
    // of source merge30s, statistics bucket60s, and old15.4 asleep grouping120s.
    double maximum_combination_gap = 29.0;
    std::size_t maximum_intervals = 100000;
};

inline LegacyProjection projectLegacySleepSummary(
    const std::vector<StageStatisticsInterval> &statistics,
    StatisticsInputState input_state,
    ProjectionConfiguration configuration = ProjectionConfiguration()) {
    LegacyProjection result;
    if (input_state != StatisticsInputState::resolved_statistics_intervals) return result;
    if (!std::isfinite(configuration.maximum_combination_gap) ||
        configuration.maximum_combination_gap < 0 || !configuration.maximum_intervals) {
        result.status_ = ProjectionStatus::invalid_configuration;
        return result;
    }
    if (statistics.size() > configuration.maximum_intervals) {
        result.status_ = ProjectionStatus::input_limit;
        return result;
    }
    // Validate ALL intervals before producing anything. Invalid trailing data
    // cannot turn an earlier partial projection into an apparently valid result.
    bool have_previous = false;
    double previous_end = 0;
    for (const auto &interval : statistics) {
        if (interval.category < 1 || interval.category > 5) {
            result.status_ = ProjectionStatus::invalid_category;
            return result;
        }
        if (!std::isfinite(interval.start) || !std::isfinite(interval.end) ||
            interval.end <= interval.start || !std::isfinite(interval.end - interval.start)) {
            // Projection requires positive-length OUTPUT intervals. Zero-length
            // fragments are meaningful upstream to reducer tie ordering, but
            // must not act as grouping bridges in derived summary output.
            result.status_ = ProjectionStatus::invalid_interval;
            return result;
        }
        if (have_previous && interval.start < previous_end) {
            result.status_ = ProjectionStatus::unordered_or_overlapping_statistics;
            return result;
        }
        have_previous = true;
        previous_end = interval.end;
    }
    try {
    std::vector<LegacyAsleepSegment> segments;
    double total = 0;
    for (const auto &interval : statistics) {
        // Awake participates upstream; here, and ONLY here, default legacy
        // projection omits its derived segment. Do not infer an Awake priority.
        if (interval.category == 2) continue;
        const double duration = interval.end - interval.start;
        if (!std::isfinite(total + duration)) {
            result.status_ = ProjectionStatus::invalid_accumulated_duration;
            return result;
        }
        total += duration;
        const double gap = segments.empty() ? 0 : interval.start - segments.back().end;
        const bool join = !segments.empty() && std::isfinite(gap) &&
            gap <= configuration.maximum_combination_gap;
        if (!join) {
            LegacyAsleepSegment segment;
            segment.start = interval.start;
            segment.end = interval.end;
            segment.sample_intervals.push_back({interval.start, interval.end});
            segments.push_back(std::move(segment));
        } else {
            LegacyAsleepSegment &segment = segments.back();
            if (!std::isfinite(interval.end - segment.start)) {
                result.status_ = ProjectionStatus::invalid_bounding_span;
                return result;
            }
            segment.end = interval.end;
            TimeInterval &last = segment.sample_intervals.back();
            // Touching sample intervals form a union. A positive grouping gap
            // is NEVER counted as asleep time, even inside one bounding segment.
            if (interval.start <= last.end) last.end = std::max(last.end, interval.end);
            else segment.sample_intervals.push_back({interval.start, interval.end});
        }
    }
    result.data_.asleep_segments = std::move(segments);
    result.data_.asleep_duration = total;
    result.status_ = ProjectionStatus::complete;
    } catch (const std::bad_alloc &) {
        result.status_ = ProjectionStatus::allocation_failure;
    } catch (const std::length_error &) {
        result.status_ = ProjectionStatus::allocation_failure;
    }
    return result;
}

} }
#endif
