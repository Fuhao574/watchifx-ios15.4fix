# 手动睡眠配置同步（开发中）

现有模块入口：WatchFix首页 → 功能 → 睡眠配置同步 → 同步操作。
不新增App，不增加首页独立功能入口；内部模块标识沿用 FocusConfigCompatibility。
不是常驻开关，不随打开页面/刷新自动同步；正常功能与一次单独的用户确认绑定。

首版只提供手机上手动同步一次 Sleep：打开模块、确认开始、按提示正常保存一次睡眠设置、
查看协议结果并结束恢复。不做持续自动同步、其他 Focus 模式或通话转发修复。
默认运行清单 `enabledForDevice=false`；手机 App 路径尚待安装验收，不要手改清单绕过。

## 代码

- `ModuleSession.h`：daemon启动捕获一个会话，目录/权限/时钟/取消检查与身份一次收据。
- `Runtime/Focus`：从成功的once3独立派生，nested内容3、额外最多一次Sleep，无控制升级。
- `Runtime/Identity`：从identitywireless派生，身份受本会话专用marker控制，不用全局shadow偏好。
- `RootLauncher.sh`：固定start/recover及UUID，不接受任意程序/路径/服务参数。
- `SleepSyncCoordinator.sh`：阶段记录、四文件备份/校验、有限身份/Focus重启、撤销恢复。
- `stage_runtime.py`：只把组件放进App私有资源；默认禁用，可显式生成品牌绑定的设备测试候选。

不要直接在主机或设备执行两个shell脚本。离线测试只对固定路径翻译后的fixture使用完整mock。

## 构建

在项目根目录使用 `make package` 的**本机打包目标**，默认包含模块；
不要使用 `make do` / install。完整日志和限制在工作区 reports 中。
正常AppsSupport/Messages/Pairing源不改。沿用FocusConfigCompatibility卡片，改为无常驻安装内容的
手动操作模块；不安装旧实验 dylib，也不参加“全部安装／删除”。

只有维护者准备明确的本机测试包时，才同时指定 `WATCHFIX_SLEEP_SYNC_BRAND`（显式十六进制）
和 `WATCHFIX_SLEEP_SYNC_TEST_CANDIDATE=1`。App会核对本机jbrand与构建绑定一致；不匹配拒绝开始。
这些构建选项不是对真实设备操作的授权，也不代表已经通过设备验收。

## 本机测试

测试源码与运行说明见 [`Tests/SleepSync`](../../Tests/SleepSync/README.md)。

- 协调器17个测试方法全量通过：包括原流程、原始截止时间、损坏时间文件及精确postload恢复。
- 会话边界37个场景通过：selector变化、权限/链接、目录替换、一次领取及撤销。
- Foundation状态投影95项断言通过，ACK不冒充用户功能验证。
- 固定启动入口16项、postload字节模型13项、打包/品牌绑定3项通过。

此前协调器测试超时已定位到夹具逐命令启动Python的开销放大；改用本地轻量客户端和常驻
mock dispatcher后有界完成。夹具同时严格检查PATH翻译，禁止意外执行主机真实设备命令。
这些结果不能替代实际设备恢复验证。

## 下一步仅做手机验收

- 已加入显式品牌对应的精确postload哈希，仍需核验真机实际变换与预测一致；未知hash不覆盖。
- 固定启动入口和恢复已通过主机模拟，尚未验证App persona／launchd／RootHide实际路径。
- 仍限定已有基线组件和iOS15.4的这套已验证组合；其他安装基线拒绝，不猜测覆盖。

历史SSH方案成功不能替代App验收。下一阶段不再增加功能：单独取得安装与模块单次同步／恢复
验证授权，确认此入口能完成已验证的原流程；当前不触发已恢复正常的手机配置。
