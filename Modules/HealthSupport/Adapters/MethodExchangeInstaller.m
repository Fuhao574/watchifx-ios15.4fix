#import "MethodExchangeInstaller.h"

#include <stdatomic.h>

// Private class that owns the dummy methods we exchange with. Every dummy lives
// here, never on a system class, so a stray send to an anchor selector cannot
// reach Apple code with the wrong receiver.
@interface WFHSExchangeAnchor : NSObject
@end
@implementation WFHSExchangeAnchor
@end

@interface WFHSMethodSlot ()
@property (nonatomic, readwrite) Class targetClass;
@property (nonatomic, readwrite) SEL targetSelector;
@property (nonatomic, readwrite) IMP wrapperImplementation;
@property (nonatomic, readwrite) IMP previousImplementation;
@property (nonatomic, readwrite) BOOL installed;
@property (nonatomic, copy, readwrite) NSString *slotName;
@property (nonatomic, assign) SEL anchorSelector;
@end

@implementation WFHSMethodSlot
@end

static NSMutableDictionary<NSString *, WFHSMethodSlot *> *WFHSSlotRegistry(void)
{
    static NSMutableDictionary *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ registry = [NSMutableDictionary dictionary]; });
    return registry;
}

static NSLock *WFHSSlotLock(void)
{
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    return lock;
}

static void WFHSSetStatus(WFHSExchangeStatus *status, WFHSExchangeStatus value)
{
    if (status) {
        *status = value;
    }
}

WFHSMethodSlot *WFHSInstallMethodExchange(Class _Nullable targetClass, SEL _Nullable selector,
                                          IMP _Nullable wrapper, NSString *slotName,
                                          WFHSExchangeStatus * _Nullable status)
{
    if (!targetClass || !selector || !wrapper || slotName.length == 0) {
        WFHSSetStatus(status, WFHSExchangeInvalidTarget);
        return nil;
    }
    Method target = class_getInstanceMethod(targetClass, selector);
    const char *types = target ? method_getTypeEncoding(target) : NULL;
    if (!target || !types) {
        WFHSSetStatus(status, WFHSExchangeInvalidTarget);
        return nil;
    }

    [WFHSSlotLock() lock];
    WFHSMethodSlot *existing = WFHSSlotRegistry()[slotName];
    if (existing) {
        [WFHSSlotLock() unlock];
        WFHSSetStatus(status, WFHSExchangeAlreadyInstalled);
        return existing;
    }

    NSString *anchorName = [@"wfhs.exchange." stringByAppendingString:slotName];
    SEL anchorSelector = sel_registerName(anchorName.UTF8String);
    if (class_getInstanceMethod([WFHSExchangeAnchor class], anchorSelector) ||
        !class_addMethod([WFHSExchangeAnchor class], anchorSelector, wrapper, types)) {
        [WFHSSlotLock() unlock];
        WFHSSetStatus(status, WFHSExchangeAddMethodFailed);
        return nil;
    }
    Method anchor = class_getInstanceMethod([WFHSExchangeAnchor class], anchorSelector);
    IMP before = method_getImplementation(target);
    method_exchangeImplementations(target, anchor);
    IMP afterTarget = method_getImplementation(target);
    IMP afterAnchor = method_getImplementation(anchor);

    WFHSMethodSlot *slot = [WFHSMethodSlot new];
    slot.targetClass = targetClass;
    slot.targetSelector = selector;
    slot.wrapperImplementation = wrapper;
    // The exchange itself captured the previous chain head. Return it even when
    // the post-read disagrees, so the wrapper can still chain to the native
    // implementation instead of being left without an original.
    slot.previousImplementation = afterAnchor;
    slot.slotName = slotName;
    slot.anchorSelector = anchorSelector;
    slot.installed = (afterTarget == wrapper && afterAnchor == before);
    if (!slot.installed) {
        // Another writer touched the table between our exchange and this read.
        // Leave the table alone: this module never restores over an unknown
        // writer. The slot is kept (not registered) so a retry under the same
        // name is refused and the wrapper never runs without a chain.
        WFHSSlotRegistry()[slotName] = slot;
        [WFHSSlotLock() unlock];
        WFHSSetStatus(status, WFHSExchangeVerificationFailed);
        return slot;
    }
    WFHSSlotRegistry()[slotName] = slot;
    [WFHSSlotLock() unlock];
    WFHSSetStatus(status, WFHSExchangeInstalled);
    return slot;
}

BOOL WFHSVerifyMethodSlot(WFHSMethodSlot *slot)
{
    if (!slot || !slot.installed) {
        return NO;
    }
    Method target = class_getInstanceMethod(slot.targetClass, slot.targetSelector);
    return target && method_getImplementation(target) == slot.wrapperImplementation;
}

BOOL WFHSRemoveMethodExchangeForTesting(WFHSMethodSlot *slot)
{
    if (!slot || !slot.installed) {
        return NO;
    }
    [WFHSSlotLock() lock];
    Method target = class_getInstanceMethod(slot.targetClass, slot.targetSelector);
    Method anchor = class_getInstanceMethod([WFHSExchangeAnchor class], slot.anchorSelector);
    if (!target || !anchor ||
        method_getImplementation(target) != slot.wrapperImplementation) {
        [WFHSSlotLock() unlock];
        return NO;
    }
    method_exchangeImplementations(target, anchor);
    BOOL restored = method_getImplementation(target) == slot.previousImplementation;
    [WFHSSlotRegistry() removeObjectForKey:slot.slotName];
    [WFHSSlotLock() unlock];
    return restored;
}

@implementation WFHSActivationGate {
    _Atomic(BOOL) _ready;
    NSString *_name;
}

+ (instancetype)gateWithName:(NSString *)name
{
    static NSMutableDictionary<NSString *, WFHSActivationGate *> *gates;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gates = [NSMutableDictionary dictionary];
        lock = [NSLock new];
    });
    [lock lock];
    @try {
        WFHSActivationGate *gate = gates[name];
        if (!gate) {
            gate = [WFHSActivationGate new];
            gate->_name = [name copy];
            gates[name] = gate;
        }
        return gate;
    } @finally {
        [lock unlock];
    }
}

- (BOOL)ready
{
    return atomic_load(&_ready);
}

- (void)publishReady
{
    atomic_store(&_ready, YES);
}

@end
