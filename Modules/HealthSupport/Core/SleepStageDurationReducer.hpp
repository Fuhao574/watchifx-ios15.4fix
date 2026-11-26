// Independently written finite-input module core based on audited iOS16 semantics.
// Not extracted Apple code; no framework, ObjC layout, DB, hook or device API.
// Only the per-time-bucket six-category duration decision, NOT source merging.
#ifndef WF_SLEEP_STAGE_DURATION_REDUCER_HPP
#define WF_SLEEP_STAGE_DURATION_REDUCER_HPP

#include "NumericPolicy.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <limits>

namespace watchfix { namespace healthsupport {

class SleepStageDurationReducer {
public:
    static constexpr std::int64_t no_stage = std::numeric_limits<std::int64_t>::max();

    SleepStageDurationReducer() noexcept {
        for (std::size_t i = 0; i < slots_.size(); ++i) {
            slots_[i] = Slot{0.0, no_stage};
        }
    }

    // Intentionally rejects inputs not covered by the audited finite-input
    // specification. Native's lack of local checks is NOT reproduced as UB.
    // Caller supplies already source-selected, split, valid category fragments.
    // No projection or Awake filtering before this step.
    bool add(std::int64_t category, double start, double end) noexcept {
        if (!valid_ || category < 0 || category >= static_cast<std::int64_t>(slots_.size()) ||
            !std::isfinite(start) || !std::isfinite(end) || end < start) {
            valid_ = false;
            return false;
        }
        const double duration = end - start;
        Slot &slot = slots_[static_cast<std::size_t>(category)];
        const double accumulated = slot.duration + duration;
        if (!std::isfinite(duration) || !std::isfinite(accumulated)) {
            valid_ = false;
            return false;
        }
        if (slot.sequence == no_stage) {
            // Reaching this limit is impossible for six valid first-seen slots,
            // but keep a defined rejection rather than relying on signed wrap.
            if (sequence_ == no_stage - 1) { valid_ = false; return false; }
            slot.sequence = ++sequence_;
        }
        slot.duration = accumulated;
        return true;
    }

    bool valid() const noexcept { return valid_; }

    struct Decision {
        bool valid;
        bool has_stage;
        std::int64_t category;
    };

    // Prefer this checked result in adapters; prevailing() alone intentionally
    // shares a sentinel for invalid and empty, matching the reference interface.
    Decision decision() const noexcept {
        const std::int64_t category = prevailing();
        return Decision{valid_, valid_ && category != no_stage, category};
    }

    std::int64_t prevailing() const noexcept {
        if (!valid_) return no_stage;
        std::int64_t best = no_stage, best_sequence = no_stage;
        double best_duration = 0.0;
        for (std::size_t i = 0; i < slots_.size(); ++i) {
            const Slot &slot = slots_[i];
            if (!(slot.duration > std::numeric_limits<double>::min())) continue;
            if (slot.duration > best_duration ||
                (slot.duration == best_duration && slot.sequence < best_sequence)) {
                best = static_cast<std::int64_t>(i);
                best_duration = slot.duration;
                best_sequence = slot.sequence;
            }
        }
        return best;
    }

private:
    struct Slot { double duration; std::int64_t sequence; };
    std::array<Slot, 6> slots_;
    std::int64_t sequence_ = 0;
    bool valid_ = true;
};

} } // namespace watchfix::healthsupport
#endif
