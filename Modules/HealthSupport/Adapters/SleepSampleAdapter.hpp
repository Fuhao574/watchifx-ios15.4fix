// Read the actual existing HKCategorySample getter chain. No HealthStore query,
// object construction, sample mutation, persistence or class discovery.
#ifndef WFHS_SLEEP_SAMPLE_ADAPTER_HPP
#define WFHS_SLEEP_SAMPLE_ADAPTER_HPP
#import <Foundation/Foundation.h>
#include "SleepStageFragments.hpp"
#include <vector>

namespace watchfix { namespace healthsupport {
enum class SleepSampleStatus {
    unverified, complete, invalid_configuration, invalid_sample,
    unordered_samples, resource_limit, allocation_failure, candidate_exception
};
struct SleepSampleAttempt {
    SleepSampleStatus status = SleepSampleStatus::unverified;
    std::vector<StageFragment> non_in_bed;
    __strong NSArray *original_in_bed = nil;
    bool complete() const noexcept { return status == SleepSampleStatus::complete && original_in_bed != nil; }
};
struct SleepStagePresenceAttempt {
    SleepSampleStatus status = SleepSampleStatus::unverified;
    bool has_stages = false;
};
// Classification only, so a proven legacy-only day need not decode source IDs
// or satisfy stage-statistics dependencies before invoking guarded original.
SleepStagePresenceAttempt inspectSleepStagePresence(NSArray *samples, Class sample_class,
    Class category_type_class, std::size_t maximum_samples = 100000);

// Caller supplies a complete nonconcurrent snapshot from the audited day builder
// and verified class/image/IMP identities. Samples and all nested getter objects
// must remain stable through this synchronous conversion. No proof is inferred
// from class names, type code alone or the caller simply passing Class values.
// Category0 stays as ORIGINAL objects for the existing native InBed path. Values
// 1..5 stay raw for source-aware statistics, including Awake2. Not a new sample.
SleepSampleAttempt readSleepSampleSnapshot(NSArray *samples, Class sample_class,
    Class category_type_class, Class source_revision_class, Class source_class,
    std::size_t maximum_samples = 100000);
} }
#endif
