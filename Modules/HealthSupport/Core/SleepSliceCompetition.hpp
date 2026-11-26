// Per-slice stage competition for overlapping raw fragments.
//
// The day builder hands us samples that may overlap across sources. Refusing
// such a day would drop a whole night of data, so overlaps are resolved into
// non-overlapping statistics intervals before projection:
//
//   cut the timeline at every fragment boundary, then in each slice ask the
//   audited six-slot reducer which category prevailed (largest duration wins,
//   equal duration keeps the first-seen category).
//
// This is the audited per-interval decision applied to slices, NOT a source
// ranking or the full iOS16 source-aware merge. A day without overlap is
// returned unchanged, so the common single-watch case keeps its exact input.
// No Apple code, HealthKit, persistence or hooks.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_SLICE_COMPETITION_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_SLICE_COMPETITION_HPP

#include "LegacyDerivedSummary.hpp"
#include "SleepStageDurationReducer.hpp"
#include "SleepStageFragments.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <new>
#include <stdexcept>
#include <vector>

namespace watchfix { namespace healthsupport {

enum class SliceCompetitionStatus {
    complete,
    invalid_input,
    input_limit,
    allocation_failure
};

struct SliceCompetitionConfiguration {
    std::size_t maximum_fragments = 4096;
    std::size_t maximum_slices = 8192;
};

struct SliceCompetitionResult {
    SliceCompetitionStatus status = SliceCompetitionStatus::invalid_input;
    // Sorted, non-overlapping, category 1..5 only (no InBed, no zero length).
    std::vector<StageStatisticsInterval> intervals;
    // True only when at least two fragments overlapped and a slice was decided
    // by competition. False means intervals are the input fragments verbatim.
    bool competed = false;
    bool complete() const noexcept { return status == SliceCompetitionStatus::complete; }
};

inline SliceCompetitionResult competeStageSlices(const std::vector<StageFragment> &fragments,
                                                 SliceCompetitionConfiguration configuration =
                                                     SliceCompetitionConfiguration())
{
    SliceCompetitionResult result;
    if (!configuration.maximum_fragments || !configuration.maximum_slices ||
        fragments.size() > configuration.maximum_fragments) {
        result.status = fragments.size() > configuration.maximum_fragments
            ? SliceCompetitionStatus::input_limit : SliceCompetitionStatus::invalid_input;
        return result;
    }
    try {
        std::vector<StageFragment> sorted = fragments;
        for (const auto &fragment : sorted) {
            if (fragment.category < 1 || fragment.category > 5 ||
                !std::isfinite(fragment.start) || !std::isfinite(fragment.end) ||
                fragment.end <= fragment.start) {
                result.status = SliceCompetitionStatus::invalid_input;
                return result;
            }
        }
        std::sort(sorted.begin(), sorted.end(),
            [](const StageFragment &left, const StageFragment &right) {
                if (left.start != right.start) return left.start < right.start;
                if (left.end != right.end) return left.end < right.end;
                if (left.category != right.category) return left.category < right.category;
                return left.source_id < right.source_id;
            });

        bool overlaps = false;
        for (std::size_t i = 1; i < sorted.size(); ++i) {
            if (sorted[i].start < sorted[i - 1].end) { overlaps = true; break; }
        }
        if (!overlaps) {
            result.intervals.reserve(sorted.size());
            for (const auto &fragment : sorted) {
                result.intervals.push_back(StageStatisticsInterval{fragment.category,
                                                                   fragment.start, fragment.end});
            }
            result.status = SliceCompetitionStatus::complete;
            return result;
        }

        std::vector<double> cuts;
        cuts.reserve(sorted.size() * 2);
        for (const auto &fragment : sorted) {
            cuts.push_back(fragment.start);
            cuts.push_back(fragment.end);
        }
        std::sort(cuts.begin(), cuts.end());
        cuts.erase(std::unique(cuts.begin(), cuts.end()), cuts.end());
        if (cuts.size() < 2 || cuts.size() - 1 > configuration.maximum_slices) {
            result.status = cuts.size() < 2 ? SliceCompetitionStatus::invalid_input
                                            : SliceCompetitionStatus::input_limit;
            return result;
        }

        for (std::size_t index = 0; index + 1 < cuts.size(); ++index) {
            const double begin = cuts[index], end = cuts[index + 1];
            if (!(end > begin)) continue;
            SleepStageDurationReducer reducer;
            bool covered = false;
            for (const auto &fragment : sorted) {
                if (fragment.start >= end) break;
                if (fragment.end <= begin) continue;
                const double start = std::max(fragment.start, begin);
                const double stop = std::min(fragment.end, end);
                if (!(stop > start)) continue;
                if (!reducer.add(fragment.category, start, stop)) {
                    result.status = SliceCompetitionStatus::invalid_input;
                    return result;
                }
                covered = true;
            }
            if (!covered) continue;
            const auto decision = reducer.decision();
            if (!decision.valid) {
                result.status = SliceCompetitionStatus::invalid_input;
                return result;
            }
            if (!decision.has_stage) continue;
            if (!result.intervals.empty() &&
                result.intervals.back().category == decision.category &&
                result.intervals.back().end == begin) {
                result.intervals.back().end = end;
            } else {
                result.intervals.push_back(StageStatisticsInterval{decision.category, begin, end});
            }
        }
        result.competed = true;
        result.status = SliceCompetitionStatus::complete;
    } catch (const std::bad_alloc &) {
        result.intervals.clear();
        result.status = SliceCompetitionStatus::allocation_failure;
    } catch (const std::length_error &) {
        result.intervals.clear();
        result.status = SliceCompetitionStatus::allocation_failure;
    }
    return result;
}

} }
#endif
