// Expanded sleepAnalysis acceptance, decided before any runtime call.
// Pure finite-input policy: no HealthKit, no ObjC, no persistence, no hook.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_ACCEPT_POLICY_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_ACCEPT_POLICY_HPP

#include <cstdint>

namespace watchfix { namespace healthsupport {

// Exact audited 15.4 code for HKCategoryTypeIdentifierSleepAnalysis.
// The type definition table entry is code63; the checker compares value <3.
inline constexpr std::int64_t sleep_analysis_category_code = 63;
// InBed0 / Asleep1 / Awake2 plus the iOS16 stage values Core3 / Deep4 / REM5.
inline constexpr std::int64_t sleep_analysis_maximum_accepted_value = 5;

struct SleepAcceptDecision {
    // false: the caller MUST return the previous implementation's result.
    // This module never answers "reject" on its own, so any value or type it
    // does not positively understand keeps the native outcome.
    bool handled = false;
    bool accepted = false;
};

// project_ready is the caller's projection gate. While it is closed the raw
// values must stay rejected: storing 3/4/5 without a working day-summary
// replacement would hand the native builder a stage-only day it cannot finish.
constexpr SleepAcceptDecision decideSleepStageValue(std::int64_t category_code,
                                                    std::int64_t value,
                                                    bool project_ready) noexcept
{
    if (!project_ready) {
        return {};
    }
    if (category_code != sleep_analysis_category_code) {
        return {};
    }
    if (value < 0 || value > sleep_analysis_maximum_accepted_value) {
        return {};
    }
    return {true, true};
}

} }
#endif
