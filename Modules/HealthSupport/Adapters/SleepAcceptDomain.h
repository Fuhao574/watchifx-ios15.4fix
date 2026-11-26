#ifndef WFHS_SLEEP_ACCEPT_DOMAIN_H
#define WFHS_SLEEP_ACCEPT_DOMAIN_H

// Expands -[HKCategoryType _acceptsValue:] for sleepAnalysis only.
//
// The audited 15.4 gate is a single predicate reached from
// -[HKCategorySample _validateWithConfiguration:] and -initWithCoder:. Both
// sites live in HealthKit, so this replacement is only correct when the dylib
// is loaded into healthd alone: a framework-wide scope would also change the
// Health app and third-party clients.
//
// Every path that is not positively understood returns the previous
// implementation's answer. The wrapper never converts a native rejection into
// an acceptance while the projection gate is closed.
#import <Foundation/Foundation.h>
#import "MethodExchangeInstaller.h"

NS_ASSUME_NONNULL_BEGIN

@interface WFHSSleepAcceptDomain : NSObject
@property (class, nonatomic, readonly) NSString *slotName;
@property (nonatomic, readonly, nullable) WFHSMethodSlot *slot;
@property (nonatomic, readonly) BOOL installed;

// The gate must be the same object the day-summary projection publishes.
+ (instancetype)domainWithGate:(WFHSActivationGate *)gate;

// categoryTypeClass is the audited HKCategoryType class. Returns NO and leaves
// the previous implementation in place when the selector or class is missing.
- (BOOL)installWithCategoryTypeClass:(Class _Nullable)categoryTypeClass
                              status:(WFHSExchangeStatus * _Nullable)status;
- (BOOL)verifyInstalled;
@end

NS_ASSUME_NONNULL_END

#endif
