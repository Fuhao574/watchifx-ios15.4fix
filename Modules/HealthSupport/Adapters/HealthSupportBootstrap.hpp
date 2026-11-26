// Single entry point for the health support install order.
//
// The acceptance wrapper may only open after the day-summary projection is
// installed and verified: storing 3/4/5 with no working projection hands the
// native builder a stage-only day it cannot finish. There is no rollback here;
// a partially installed process keeps the projection and leaves acceptance
// closed, which is exactly the previous behaviour for new samples.
#ifndef WFHS_HEALTH_SUPPORT_BOOTSTRAP_HPP
#define WFHS_HEALTH_SUPPORT_BOOTSTRAP_HPP

#import <Foundation/Foundation.h>
#include "DayProjectionAdapter.hpp"
#include "DayProjectionInstall.hpp"
#include "MethodExchangeInstaller.h"
#include "SleepAcceptDomain.h"

#include <cstddef>

NS_ASSUME_NONNULL_BEGIN

@interface WFHSHealthSupportSetup : NSObject
@property (nonatomic, readonly) BOOL ready;
@property (nonatomic, strong, readonly, nullable) WFHSMethodSlot *projectionSlot;
@property (nonatomic, strong, readonly, nullable) WFHSMethodSlot *acceptanceSlot;
@property (nonatomic, readonly) WFHSExchangeStatus projectionStatus;
@property (nonatomic, readonly) WFHSExchangeStatus acceptanceStatus;
@end

// Verifies class identity? No: the caller must pass classes from an
// independently verified exact-build bootstrap. This function only orders the
// two installs and publishes the gate when both are verified.
FOUNDATION_EXPORT WFHSHealthSupportSetup *WFHSSetupHealthSupport(
    const watchfix::healthsupport::DayProjectionClasses &classes,
    Class _Nullable categoryTypeClass, WFHSActivationGate *gate,
    std::size_t maximumSamples, std::size_t maximumSegments);

NS_ASSUME_NONNULL_END
#endif
