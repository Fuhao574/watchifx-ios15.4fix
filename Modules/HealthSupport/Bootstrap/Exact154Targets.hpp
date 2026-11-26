// Exact iOS15.4 target resolution for the health support install surface.
//
// Every class is looked up by its audited name with objc_getClass (no image
// loading, no +initialize) and must live in the audited image with the audited
// UUID. The two replaced methods are then re-checked for owner, ABI and
// image-relative IMP offset:
//
//   -[HDSleepDaySummaryBuilder createDaySummary]      HealthDaemon +0x6b24f4
//   -[HKCategoryType _acceptsValue:]                  HealthKit    +0xcb18
//
// A mismatch is a hard refusal: the caller must not install anything. This is
// still metadata, not proof that the process or the images are trustworthy,
// and it does not close a check-use race.
#ifndef WFHS_EXACT154_TARGETS_HPP
#define WFHS_EXACT154_TARGETS_HPP

#import <Foundation/Foundation.h>
#include "DayProjectionAdapter.hpp"

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    watchfix::healthsupport::DayProjectionClasses classes;
    Class _Nullable category_type;
} WFHSExact154Targets;

// Fills out on success. On failure returns NO, leaves out untouched and
// appends one line per failed check to failures when it is provided.
FOUNDATION_EXPORT BOOL WFHSResolveExact154Targets(WFHSExact154Targets * _Nullable out,
                                                  NSMutableArray<NSString *> * _Nullable failures);

NS_ASSUME_NONNULL_END
#endif
