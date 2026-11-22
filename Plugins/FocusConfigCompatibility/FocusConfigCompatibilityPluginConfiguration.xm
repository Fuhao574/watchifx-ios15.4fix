#import <Foundation/Foundation.h>
#import "PluginConfig.h"

static NSString *const kFocusConfigCompatibilityHooksEnabledKey = @"FocusConfigCompatibilityHooksEnabled";

@interface FocusConfigCompatibilityPluginConfiguration : NSObject <WFPluginConfigurationProvider>
@end

@implementation FocusConfigCompatibilityPluginConfiguration

+ (NSDictionary<NSString *, id> *)configurationPageWithContext:(WFPluginConfigurationContext *)context {
    (void)context;
    return @{
        @"title": @"睡眠配置同步",
        @"savedMessage": @"此模块使用手动单次同步，不通过常驻实验开关启用。",
        @"sections": @[
            @{
                @"title": @"手动同步一次",
                @"footer": @"请在 WatchFix 功能模块列表中打开本模块的操作页。每次明确确认后最多附加一条无删除的睡眠配置更新，观察结果后恢复临时组件；不是持续自动同步。当前协调恢复仍在验收，未通过前不能开始。",
                @"controls": @[],
            },
        ],
    };
}

+ (NSDictionary<NSString *, id> *)normalizedConfiguration:(NSDictionary<NSString *, id> *)configuration
                                                  context:(WFPluginConfigurationContext *)context {
    (void)context;
    (void)configuration;
    return @{kFocusConfigCompatibilityHooksEnabledKey: @NO};
}

@end
