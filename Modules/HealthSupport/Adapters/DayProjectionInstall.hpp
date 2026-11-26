// Runtime wiring for the day-summary projection.
//
// Installs exactly one replacement, on -[HDSleepDaySummaryBuilder
// createDaySummary], and never consults the acceptance gate: stored stage
// values outlive a reboot, so the projection must run even when new acceptance
// is off. The gate belongs to the acceptance wrapper only.
//
// This file does not verify image/UUID/IMP identity. The caller must pass
// classes obtained from an independently verified exact-build bootstrap.
#ifndef WFHS_DAY_PROJECTION_INSTALL_HPP
#define WFHS_DAY_PROJECTION_INSTALL_HPP

#import <Foundation/Foundation.h>
#include "DayProjectionAdapter.hpp"
#include "MethodExchangeInstaller.h"

#include <cstddef>

NS_ASSUME_NONNULL_BEGIN

// One installation per process. Returns nil on invalid input or duplicate
// install; status carries the exchange result. The wrapper stays installed for
// the life of the process: there is no production removal.
FOUNDATION_EXPORT WFHSMethodSlot * _Nullable WFHSInstallDayProjection(
    const watchfix::healthsupport::DayProjectionClasses &classes,
    std::size_t maximum_samples, std::size_t maximum_segments,
    WFHSExchangeStatus * _Nullable status);

NS_ASSUME_NONNULL_END
#endif
