#ifndef WFHS_METHOD_EXCHANGE_INSTALLER_H
#define WFHS_METHOD_EXCHANGE_INSTALLER_H

// Atomic-capture method exchange for the health support install surface.
//
// The 15.4 runtime has no expected-IMP conditional write, so "check then
// method_setImplementation" can silently drop a third party's chain. Exchanging
// with a private anchor method instead gives us the previous IMP atomically
// under the runtime lock, and never writes an IMP that was not already present.
//
// This file does not install anything by itself, does not know about healthd,
// HealthKit or sleep categories, and has no constructor. A caller must supply
// the exact class/selector and must gate the wrapper's behaviour on its own
// readiness flag. There is no production uninstall: removing a slot is for
// offline tests only.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WFHSExchangeStatus) {
    WFHSExchangeInstalled = 0,
    WFHSExchangeAlreadyInstalled,
    WFHSExchangeInvalidTarget,
    WFHSExchangeAddMethodFailed,
    WFHSExchangeVerificationFailed,
    WFHSExchangeMissingSlot,
};

@interface WFHSMethodSlot : NSObject
@property (nonatomic, readonly) Class targetClass;
@property (nonatomic, readonly) SEL targetSelector;
@property (nonatomic, readonly) IMP wrapperImplementation;
// Previous chain head, captured by the exchange itself. Immutable after install.
@property (nonatomic, readonly) IMP previousImplementation;
@property (nonatomic, readonly) BOOL installed;
@property (nonatomic, copy, readonly) NSString *slotName;
@end

// Installs once per slotName. On failure nothing is left half-written beyond an
// unused private anchor method; the target method table is only touched by the
// exchange, and a failed verification is reported, never "rolled back" blindly.
FOUNDATION_EXPORT WFHSMethodSlot * _Nullable WFHSInstallMethodExchange(
    Class _Nullable targetClass, SEL _Nullable selector, IMP _Nullable wrapper,
    NSString *slotName, WFHSExchangeStatus * _Nullable status);

// True only while the target still dispatches to our wrapper.
FOUNDATION_EXPORT BOOL WFHSVerifyMethodSlot(WFHSMethodSlot *slot);

// Offline test only. Swaps back only when the target still holds our wrapper;
// returns NO when another writer took over, so a test can detect it instead of
// guessing. Never call this from a production path.
FOUNDATION_EXPORT BOOL WFHSRemoveMethodExchangeForTesting(WFHSMethodSlot *slot);

// One-way activation flag. Wrappers must treat NO as "behave exactly like the
// previous implementation"; nothing may turn it back off except process exit,
// because stored data may already depend on the replacement.
@interface WFHSActivationGate : NSObject
+ (instancetype)gateWithName:(NSString *)name;
@property (nonatomic, readonly) BOOL ready;
- (void)publishReady;
@end

NS_ASSUME_NONNULL_END

#endif
