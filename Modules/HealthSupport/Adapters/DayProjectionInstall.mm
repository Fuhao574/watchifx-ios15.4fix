#include "DayProjectionInstall.hpp"

@interface WFHSDayProjectionState : NSObject
@property (nonatomic, strong) WFHSMethodSlot *slot;
@property (nonatomic, assign) std::size_t maximumSamples;
@property (nonatomic, assign) std::size_t maximumSegments;
- (instancetype)initWithClasses:(const watchfix::healthsupport::DayProjectionClasses &)classes;
- (const watchfix::healthsupport::DayProjectionClasses &)classes;
@end

@implementation WFHSDayProjectionState {
    watchfix::healthsupport::DayProjectionClasses _classes;
}

- (instancetype)initWithClasses:(const watchfix::healthsupport::DayProjectionClasses &)classes
{
    self = [super init];
    if (self) {
        _classes = classes;
    }
    return self;
}

- (const watchfix::healthsupport::DayProjectionClasses &)classes
{
    return _classes;
}

@end

static WFHSDayProjectionState *gProjectionState;
id WFHSDayProjection(id self, SEL _cmd);
static id WFHSDayProjectionWrapper(id self, SEL _cmd);

id WFHSDayProjection(id self, SEL _cmd)
{
    (void)_cmd;
    WFHSDayProjectionState *state = gProjectionState;
    IMP original = state.slot.previousImplementation;
    if (!original) {
        // Nothing to chain to; emitting nothing is safer than guessing.
        return nil;
    }
    id (*call)(id, SEL) = (id (*)(id, SEL))original;
    const auto attempt = watchfix::healthsupport::projectSleepDaySummary(
        self, [state classes], state.maximumSamples, state.maximumSegments);
    if (attempt.complete()) {
        return attempt.summary;
    }
    if (attempt.native_fallback_safe) {
        return call(self, _cmd);
    }
    // Stage values are present but the projection could not finish. Reaching
    // the native builder here would run its empty-period finish on a stage-only
    // day, so the day is skipped instead.
    return nil;
}

static id WFHSDayProjectionWrapper(id self, SEL _cmd)
{
    return WFHSDayProjection(self, _cmd);
}

WFHSMethodSlot *WFHSInstallDayProjection(
    const watchfix::healthsupport::DayProjectionClasses &classes,
    std::size_t maximum_samples, std::size_t maximum_segments, WFHSExchangeStatus *status)
{
    if (!maximum_samples || !maximum_segments ||
        !classes.builder || !classes.calendar_cache || !classes.sample || !classes.category_type ||
        !classes.source_revision || !classes.source || !classes.segment || !classes.period_builder ||
        !classes.period || !classes.summary || !classes.segment_builder) {
        if (status) {
            *status = WFHSExchangeInvalidTarget;
        }
        return nil;
    }
    if (gProjectionState) {
        if (status) {
            *status = WFHSExchangeAlreadyInstalled;
        }
        return gProjectionState.slot;
    }
    WFHSDayProjectionState *state = [[WFHSDayProjectionState alloc] initWithClasses:classes];
    if (!state) {
        if (status) {
            *status = WFHSExchangeAddMethodFailed;
        }
        return nil;
    }
    state.maximumSamples = maximum_samples;
    state.maximumSegments = maximum_segments;
    // Published before the exchange: the wrapper may be reached as soon as the
    // target method table points at it.
    gProjectionState = state;
    WFHSMethodSlot *slot = WFHSInstallMethodExchange(classes.builder, @selector(createDaySummary),
                                                     (IMP)WFHSDayProjectionWrapper,
                                                     @"dayProjection.createDaySummary", status);
    if (!slot) {
        gProjectionState = nil;
        return nil;
    }
    state.slot = slot;
    return slot;
}
