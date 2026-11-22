#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@class WFPluginConfigurationContext;
@interface WFSleepSyncBridge : NSObject
+ (NSDictionary<NSString *,id> *)snapshot;
+ (BOOL)startWithError:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none))) NS_SWIFT_NAME(start(error:));
+ (BOOL)cancelWithError:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none))) NS_SWIFT_NAME(cancel(error:));
+ (BOOL)recoverWithError:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none))) NS_SWIFT_NAME(recover(error:));
+ (BOOL)setRegistered:(BOOL)enabled context:(WFPluginConfigurationContext *)context error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
