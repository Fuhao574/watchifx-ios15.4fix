// Finalized statistics bucket -> derived category interval. No calendar
// reconstruction, fixed86400-second day, raw sample clipping or persistence.
#ifndef WATCHFIX_HEALTH_SUPPORT_SLEEP_STATISTICS_BUCKET_OUTPUT_HPP
#define WATCHFIX_HEALTH_SUPPORT_SLEEP_STATISTICS_BUCKET_OUTPUT_HPP

#include "SleepStageDurationReducer.hpp"
#include "LegacyDerivedSummary.hpp"
#include <cmath>

namespace watchfix { namespace healthsupport {

// A boundary pair obtained from one audited native _HKDateIntervalCollection
// dateIntervalAtIndex:/dateIntervalContainingDate:index: result. Supplying this
// struct does not establish the native calendar/anchor provenance by itself.
struct CalendarBucketBounds { double start; double end; };

enum class BucketOutputStatus {
    interval,
    no_prevailing_stage,
    not_finalized,
    invalid_bounds,
    invalid_reducer,
    in_bed_category_not_supported
};

class BucketOutput;
BucketOutput finalizeSleepStatisticsBucket(const SleepStageDurationReducer &,
    CalendarBucketBounds, bool) noexcept;

class BucketOutput {
public:
    BucketOutputStatus status() const noexcept { return status_; }
    bool succeeded() const noexcept {
        return status_ == BucketOutputStatus::interval || status_ == BucketOutputStatus::no_prevailing_stage;
    }
    // A successful no-stage bucket is different from a failed bucket, and does
    // not synthesize category0/1 or an empty category interval.
    const StageStatisticsInterval *interval() const noexcept {
        return status_ == BucketOutputStatus::interval ? &interval_ : nullptr;
    }
private:
    BucketOutputStatus status_ = BucketOutputStatus::not_finalized;
    StageStatisticsInterval interval_{0, 0, 0};
    friend BucketOutput finalizeSleepStatisticsBucket(const SleepStageDurationReducer &,
        CalendarBucketBounds, bool) noexcept;
};

// Upstream must finish native-equivalent advancement/bucket transitions before
// passing finalized=true. The flag is an interface precondition, not proof of
// calendar, source selection, ledger or event-dispatch completeness.
inline BucketOutput finalizeSleepStatisticsBucket(const SleepStageDurationReducer &reducer,
                                                   CalendarBucketBounds bounds,
                                                   bool finalized) noexcept {
    BucketOutput result;
    if (!finalized) return result;
    if (!std::isfinite(bounds.start) || !std::isfinite(bounds.end) || bounds.end <= bounds.start ||
        !std::isfinite(bounds.end - bounds.start)) {
        result.status_ = BucketOutputStatus::invalid_bounds;
        return result;
    }
    const auto decision = reducer.decision();
    if (!decision.valid) {
        result.status_ = BucketOutputStatus::invalid_reducer;
        return result;
    }
    if (!decision.has_stage) {
        result.status_ = BucketOutputStatus::no_prevailing_stage;
        return result;
    }
    // InBed0 belongs to the separate native branch. Never silently project it
    // into asleep or feed it to the non-InBed statistics output interface.
    if (decision.category == 0) {
        result.status_ = BucketOutputStatus::in_bed_category_not_supported;
        return result;
    }
    // Native statistics outputs use the complete calendar bucket, even if the
    // contributing fragment covers only a short part. Do not use earliest/latest
    // contribution endpoints or trim the last bucket to sample.end here.
    result.interval_ = {decision.category, bounds.start, bounds.end};
    result.status_ = BucketOutputStatus::interval;
    return result;
}

} }
#endif
