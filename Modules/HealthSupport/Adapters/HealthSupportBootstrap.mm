#include "HealthSupportBootstrap.hpp"

@interface WFHSHealthSupportSetup ()
@property (nonatomic, readwrite) BOOL ready;
@property (nonatomic, strong, readwrite, nullable) WFHSMethodSlot *projectionSlot;
@property (nonatomic, strong, readwrite, nullable) WFHSMethodSlot *acceptanceSlot;
@property (nonatomic, readwrite) WFHSExchangeStatus projectionStatus;
@property (nonatomic, readwrite) WFHSExchangeStatus acceptanceStatus;
@end

@implementation WFHSHealthSupportSetup
@end

WFHSHealthSupportSetup *WFHSSetupHealthSupport(
    const watchfix::healthsupport::DayProjectionClasses &classes,
    Class categoryTypeClass, WFHSActivationGate *gate,
    std::size_t maximumSamples, std::size_t maximumSegments)
{
    WFHSHealthSupportSetup *setup = [WFHSHealthSupportSetup new];
    if (!gate) {
        setup.projectionStatus = WFHSExchangeInvalidTarget;
        setup.acceptanceStatus = WFHSExchangeInvalidTarget;
        return setup;
    }

    WFHSExchangeStatus projectionStatus = WFHSExchangeInvalidTarget;
    setup.projectionSlot = WFHSInstallDayProjection(classes, maximumSamples, maximumSegments,
                                                    &projectionStatus);
    setup.projectionStatus = projectionStatus;
    if (!setup.projectionSlot.installed) {
        // No projection means no acceptance: leave every new stage value to the
        // native rejection path rather than create data we cannot summarise.
        setup.acceptanceStatus = WFHSExchangeInvalidTarget;
        return setup;
    }
    if (!categoryTypeClass) {
        // The projection alone is still required for stage values stored by an
        // earlier boot; only new acceptance has to stay closed.
        setup.acceptanceStatus = WFHSExchangeInvalidTarget;
        return setup;
    }

    WFHSSleepAcceptDomain *domain = [WFHSSleepAcceptDomain domainWithGate:gate];
    WFHSExchangeStatus acceptanceStatus = WFHSExchangeInvalidTarget;
    const BOOL accepted = [domain installWithCategoryTypeClass:categoryTypeClass
                                                        status:&acceptanceStatus];
    setup.acceptanceSlot = domain.slot;
    setup.acceptanceStatus = acceptanceStatus;
    if (!accepted || !setup.acceptanceSlot.installed ||
        !WFHSVerifyMethodSlot(setup.projectionSlot)) {
        // The projection stays installed on purpose: it is harmless on its own
        // and any stage value stored by an earlier boot still needs it.
        return setup;
    }
    [gate publishReady];
    setup.ready = YES;
    return setup;
}
