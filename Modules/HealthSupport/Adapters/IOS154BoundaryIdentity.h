#import "LoadedMethodIdentity.h"
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, WFHSIOS154Boundary) {
    WFHSIOS154EnumeratorInitialize,
    WFHSIOS154EnumeratorEnumerate,
    WFHSIOS154DayInitialize,
    WFHSIOS154DayAddSample,
    WFHSIOS154DayCreate,
    WFHSIOS154PeriodFinish,
    WFHSIOS154StageInsert
};

// Fixed19E241 metadata contract, not a runtime allow/enable gate. Classes must
// already be valid and loaded; no class discovery, hook installation or lookup
// by untrusted name. Never use returned methods as fixed-address call targets.
// These boundaries alone are NOT all transitive callees or caller provenance.
FOUNDATION_EXPORT WFHSLoadedMethodIdentity * _Nullable WFHSCheckIOS154Boundary(
    WFHSIOS154Boundary boundary, Class actualClass);
NS_ASSUME_NONNULL_END
