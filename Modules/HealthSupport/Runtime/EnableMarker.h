// Durable enable marker for the runtime layer.
//
// The tweak is loaded into healthd by the filter, but loading must not change
// anything. Two separate markers are required:
//
//   projection  install the day-summary replacement (safe on its own: days
//               without stage values pass straight through)
//   accept      additionally open raw 0..5 acceptance
//
// Keeping them separate is what makes "turn acceptance off" possible without
// removing the projection, because stage values already stored in the health
// database still need it.
//
// The marker must be a single-link regular file, owned by the user healthd runs
// as, mode 0600, at most 128 bytes, containing exactly:
//
//   WFHS-ENABLE-V1 <kern.osversion>\n
//
// The build string is compared with the running system, so a marker left over
// from a previous iOS build never activates.
#ifndef WFHS_ENABLE_MARKER_H
#define WFHS_ENABLE_MARKER_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, WFHSEnableMarkerState) {
    WFHSEnableMarkerAbsent = 0,
    WFHSEnableMarkerValid,
    WFHSEnableMarkerNotRegular,
    WFHSEnableMarkerWrongOwner,
    WFHSEnableMarkerWrongMode,
    WFHSEnableMarkerWrongSize,
    WFHSEnableMarkerWrongContent,
    WFHSEnableMarkerReadFailed
};

FOUNDATION_EXPORT NSString *WFHSEnableMarkerStateName(WFHSEnableMarkerState state);
// expectedBuild is the current kern.osversion; empty values are refused.
FOUNDATION_EXPORT WFHSEnableMarkerState WFHSReadEnableMarker(NSString *path, NSString *expectedBuild);

#endif
