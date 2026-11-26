#import "SleepAcceptDomain.h"
#include "SleepAcceptPolicy.hpp"

#include <stdatomic.h>

@protocol WFHSCategoryTypeIdentifying <NSObject>
- (NSString *)identifier;
@end

static NSString *const WFHSSleepAnalysisIdentifier = @"HKCategoryTypeIdentifierSleepAnalysis";

static WFHSSleepAcceptDomain *gActiveDomain;

BOOL WFHSSleepAcceptValue(id self, SEL _cmd, int64_t value);
static BOOL WFHSSleepAcceptValueWrapper(id self, SEL _cmd, int64_t value);

@interface WFHSSleepAcceptDomain ()
@property (nonatomic, strong, readwrite) WFHSActivationGate *gate;
@property (nonatomic, strong, readwrite, nullable) WFHSMethodSlot *slot;
@end

@implementation WFHSSleepAcceptDomain {
    _Atomic(uintptr_t) _confirmedType;
}

+ (NSString *)slotName
{
    return @"accept.sleepStageValues";
}

+ (instancetype)domainWithGate:(WFHSActivationGate *)gate
{
    NSParameterAssert(gate);
    WFHSSleepAcceptDomain *domain = [WFHSSleepAcceptDomain new];
    domain.gate = gate;
    return domain;
}

- (BOOL)installed
{
    return self.slot.installed;
}

// Identity check by the public identifier string. Cached only after a positive
// match, so a transient failure never becomes a permanent "this is sleep".
- (BOOL)isSleepAnalysisType:(id)type
{
    uintptr_t known = atomic_load(&_confirmedType);
    if (known != 0 && known == (uintptr_t)(__bridge void *)type) {
        return YES;
    }
    id<WFHSCategoryTypeIdentifying> identifying = type;
    NSString *identifier = [identifying identifier];
    if (![identifier isKindOfClass:NSString.class] ||
        ![identifier isEqualToString:WFHSSleepAnalysisIdentifier]) {
        return NO;
    }
    atomic_store(&_confirmedType, (uintptr_t)(__bridge void *)type);
    return YES;
}

- (BOOL)installWithCategoryTypeClass:(Class)categoryTypeClass
                              status:(WFHSExchangeStatus *)status
{
    if (self.slot) {
        if (status) {
            *status = self.slot.installed ? WFHSExchangeAlreadyInstalled
                                          : WFHSExchangeVerificationFailed;
        }
        return self.slot.installed;
    }
    // Published before the exchange so the wrapper can resolve its chain even
    // if it is reached during installation.
    gActiveDomain = self;
    WFHSMethodSlot *slot = WFHSInstallMethodExchange(categoryTypeClass,
                                                     @selector(_acceptsValue:),
                                                     (IMP)WFHSSleepAcceptValueWrapper,
                                                     [WFHSSleepAcceptDomain slotName], status);
    if (!slot) {
        gActiveDomain = nil;
        return NO;
    }
    self.slot = slot;
    return slot.installed;
}

- (BOOL)verifyInstalled
{
    return WFHSVerifyMethodSlot(self.slot);
}

@end

BOOL WFHSSleepAcceptValue(id self, SEL _cmd, int64_t value)
{
    (void)_cmd;
    WFHSSleepAcceptDomain *domain = gActiveDomain;
    IMP original = domain.slot.previousImplementation;
    if (!original) {
        // No chain means we cannot reproduce the native answer. Rejecting is
        // the only direction that cannot create an unserviceable stored value.
        return NO;
    }
    BOOL (*call)(id, SEL, int64_t) = (BOOL (*)(id, SEL, int64_t))original;
    @try {
        if (domain.gate.ready && [domain isSleepAnalysisType:self]) {
            const auto decision = watchfix::healthsupport::decideSleepStageValue(
                watchfix::healthsupport::sleep_analysis_category_code, value, true);
            if (decision.handled && decision.accepted) {
                return YES;
            }
        }
    } @catch (NSException *candidateException) {
        (void)candidateException;
    }
    return call(self, _cmd, value);
}

static BOOL WFHSSleepAcceptValueWrapper(id self, SEL _cmd, int64_t value)
{
    return WFHSSleepAcceptValue(self, _cmd, value);
}
