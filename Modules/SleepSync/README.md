# 手动睡眠配置同步（开发中）

现有模块入口：WatchFix首页 → 功能 → 睡眠配置同步 → 同步操作。
不新增App，不增加首页独立功能入口；内部模块标识沿用 FocusConfigCompatibility。
不是常驻开关，不随打开页面/刷新自动同步；正常功能与一次单独的用户确认绑定。

当前只完成本地UI、桥接、会话化hooks及后台协调草稿；运行清单
`enabledForDevice=false`，因此开始按钮不可用。不要手改为true绕过验收。

## 代码

- `ModuleSession.h`：daemon启动捕获一个会话，目录/权限/时钟/取消检查与身份一次收据。
- `Runtime/Focus`：从成功的once3独立派生，nested内容3、额外最多一次Sleep，无控制升级。
- `Runtime/Identity`：从identitywireless派生，身份受本会话专用marker控制，不用全局shadow偏好。
- `RootLauncher.sh`：固定start/recover及UUID，不接受任意程序/路径/服务参数。
- `SleepSyncCoordinator.sh`：阶段记录、四文件备份/校验、有限身份/Focus重启、撤销恢复。
- `stage_runtime.py`：只把运行组件放进App私有资源，固定设备禁用；不会永久注入。

不要直接在主机或设备执行两个shell脚本。离线测试只对固定路径翻译后的fixture使用完整mock。

## 构建

在项目根目录使用 `WATCHFIX_WITH_SLEEP_SYNC=1 make package` 的**本机打包目标**；
不要使用 `make do` / install。完整日志和限制在工作区 reports 中。
正常AppsSupport/Messages/Pairing源不改；原Focus研究模块仍是独立旧模块，不是新手动入口。

## 本机测试

测试源码与运行说明见 [`Tests/SleepSync`](../../Tests/SleepSync/README.md)。

- 协调器13个测试方法全量通过：正常流程、无源/无ACK、取消、恢复重入、部分安装、未知哈希等。
- 会话边界37个场景通过：selector变化、权限/链接、目录替换、一次领取及撤销。
- Foundation状态投影95项断言通过，ACK不冒充用户功能验证。

此前协调器测试超时已定位到夹具逐命令启动Python的开销放大；改用本地轻量客户端和常驻
mock dispatcher后全量约42秒完成。夹具同时严格检查PATH翻译，禁止意外执行主机真实设备命令。
这些结果不能替代实际设备恢复验证。

## 尚未通过

- RootHide实际加载变换后的哈希未加入新runtime恢复白名单，未知hash不覆盖。
- 新root launcher和注册前窗口尚无完整故障/设备验证。
- worker总deadline需收紧至selector既定deadline。

历史SSH方案成功不能替代这些App路径验收。下一阶段先修复/验证上述本机问题，
再单独获取安装与真实App同步验证授权，不触发目前已恢复正常的手机配置。
