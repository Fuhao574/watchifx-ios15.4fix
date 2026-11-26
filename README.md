<div align="center">

<img src="./WatchFix.png" alt="WatchFix" width="150" />

# watchifx-ios15.4fix

</div>

本项目 fork 自 **[577fkj/WatchFix](https://github.com/577fkj/WatchFix)**，在原项目基础上针对
**iOS 15.4** 进行修复与扩展。原项目及原作者的贡献与署名保留，本仓库不是上游官方版本。

## 本分支的主要改动

- **修复 iOS 15.4 的信息自动卸载模块**：修正 AppsSupport 中的 Messages（信息）自动卸载修复逻辑。
- **新增睡眠模式同步模块**：在现有 WatchFix 功能列表中手动同步一次睡眠专注模式配置，
  保留 App／联系人例外，完成后撤回临时组件。
- **修复 iOS 15.4 的照片图库支持**：修正消息响应 context、快照回复的重复握手及照片导出回调，
  已在本轮设备上观察到资源发送，并由用户确认手表相簿内出现照片。
- 保留正常 AppsSupport、Messages 和 PairingCompatibility 等已有功能。

## 睡眠模式同步

入口：**WatchFix → 功能 → 睡眠配置同步 → 设置**。

1. 点击开始并确认，等待页面提示保存设置。
2. 记下系统“睡眠”专注模式中“隐藏通知标记”的原值，按提示切换一次，再返回 WatchFix。
3. 查看各阶段独立进度条，等待确认与清理完成；随后恢复该设置原值，并测试手表上的睡眠功能。

功能卡片提供 **设置／删除**；删除后可重新安装模块。运行中的会话需先完成恢复。
模块不依赖 SSH 或电脑在线，不需要为正常使用保留 OpenSSH。

### 验证范围与限制

- 已在 **iOS 15.4（19E241）／watchOS 11.5（22T572）** 组合完成 App 内单次同步、
  真实 ACK 匹配与自动清理，用户已确认睡眠功能测试通过。
- 目前只支持手动单次 Sleep 配置同步，不是持续自动同步，也不覆盖所有专注模式。
- 同步会临时调整身份并重启相关服务，连接可能短暂中断；不会自动重复发送。
- ACK 是协议确认，不等于所有配置在手表上的实际行为均已验证。其他系统／设备组合仍待测试。
- 微信实时来电转发是独立问题，不属于此模块的修复范围。

实现与详细限制见 [`Modules/SleepSync/README.md`](Modules/SleepSync/README.md)，
本机测试见 [`Tests/SleepSync/README.md`](Tests/SleepSync/README.md)。
源码仓库不包含设备诊断、私人配置／例外、固件、SSH 凭据或研究构建产物。

## 照片图库支持

在 **iOS 15.4／watchOS 11.5** 组合上，本轮修补已走通快照、照片请求、导出与资源发送，
用户确认手表相簿内已出现照片。相簿名先出现、内容稍后填充是不同阶段，不能仅凭空相簿
认定已经传输完成或失败。首次同步可能需要等待系统调度，避免反复重启服务或切换同步设置。

目前确认的是本轮照片显示，不保证整个相册全部同步、后续增删、所有媒体类型或其他系统组合。
主机回归测试见 [`Tests/PhotoLibrarySupport/README.md`](Tests/PhotoLibrarySupport/README.md)。

## 上游已有功能

- Fix Message auto uninstall
- Ping My Watch

以下功能沿用上游；本分支未逐项重新验收：

- Fix Pairing
- System Update
- Cellular Support
- Lockdown Mode Support
- Watch Face Support
- Layout Support
- Media Sync Support
- Maps Support

### Health Support（限定设备验证）

- Health Support（已纳入 WatchFix 插件构建；默认不启用）

健康兼容模块已纳入本工程，并包含已在 iOS 15.4/19E241 真机验证过的 healthd Runtime；
默认不启用，只有用户在 WatchFix 中安装该插件时才写入标记并加载。可通过
`make healthsupport-offline-check` 做离线隔离检查；StressWatch 的第三方客户端读取仍未解决，
也不代表历史补回或 iOS16 阶段图已支持。

其他功能仍可能存在兼容性问题。本文中的 iOS 15.4 修复和睡眠同步验证结果，不代表上列功能在所有环境中均可用。

## 上游作者赞助链接

- [Patreon](https://patreon.com/577FKJ)
- [爱发电](https://afdian.com/a/577fkj)

## Build

### Requirements

- MacOS

### Step

1. Install [theos](https://github.com/roothide/theos)
2. Run `make package`

默认构建已包含睡眠模块，但运行清单保持 `enabledForDevice=false`，不是通用设备可执行发行包。
维护者可按模块文档显式生成 RootHide 品牌绑定的测试候选；不要手改清单绕过设备绑定。
构建不等于安装或开始同步，`make package` 不会连接手机。

### 构建注意事项（2026-11-26 真机回归）

本次 `2.0.12~sleepsync3-1+debug` 已由用户确认 WatchFix 能打开、睡眠配置同步页面
不再显示“后端不可用”。这不是重新执行一次睡眠配置同步的验收，也不代表 StressWatch 睡眠读取已修复。

1. **保持 App 非容器化 entitlement。** `App/Entitlements.xml` 中
   `com.apple.private.security.container-required` 必须只出现一次，值为 `false`，与
   `com.apple.private.security.no-container=true` 一致。此前去除重复键时错误地保留了
   `container-required=true`，新 App 注册成容器化后无法正常启动；恢复为 `false` 后用户确认能打开。
   不要为了让签名器通过而随意删权限或保留相反的重复键。
2. **签名器必须实际可执行。** 可用 `WATCHFIX_LDID=/absolute/path/to/ldid` 指定本机签名器；
   本轮 Homebrew 的 ldid 因依赖旧 libplist 失效，采用本机独立副本修正依赖后，先给这个 macOS
   工具副本重新签名，再用于 iOS 产物签名。不要修改 Homebrew/系统库来兜底。
   Apple `codesign` 与 ldid 的参数不同（`--entitlements` / `-S`），不能直接互换。
   签名验证成功不等于设备可启动；此前仅凭闪退就把原因归于 ad-hoc 签名并不充分。
3. **SleepSync 普通构建默认不可用，这是安全门。** 若要保留已验证设备上的睡眠配置同步，
   必须显式生成品牌绑定包，不能漏掉下面两个参数，也不能安装后手改清单：

   ```sh
   # 设备品牌值由维护者另行只读确认，不写死进公开源码。
   export WATCHFIX_SLEEP_SYNC_BRAND='<目标设备的十六进制 jbrand>'
   export WATCHFIX_SLEEP_SYNC_TEST_CANDIDATE=1
   export THEOS='/absolute/path/to/theos'
   export WATCHFIX_LDID='/absolute/path/to/working/ldid'
   make package FINALPACKAGE=0
   ```

   打包后检查 `SleepSyncRuntime/module-info.plist` 的 `enabledForDevice=true`、
   `brandHex` 与目标设备一致，核对 `payload.sha256` / `postload.sha256`。
   **设备绑定包不可当作通用发行包**；其他品牌的设备需要重新构建，不能绕过绑定校验。
4. **私有 Runtime 的构建路径必须与 staging 一致。** SleepSync 的 Focus/Identity 递归构建
   使用组件各自的 `.theos/obj`；不要拿 `.theos/obj/debug` 或旧目录里的同名二进制顶替。
   缺少签名、过期源码或 postload 哈希不通过时停止打包，不删除校验。
5. **HealthSupport 只生成 arm64e 单切片。** `Plugins/HealthSupport/Makefile` 独立固定
   `ARCHS=arm64e`，不能随主 App 改回 fat。普通打包只将插件放入 App 内；不要随包自动启用
   healthd hook。已接收阶段后须保留 projection 读取保护，停接收不等于删除全部保护文件。
6. **核对实际生成包，不能只看文件名。** Theos 可能递增文件名而复用旧 control；以构建日志中
   的确切文件为准，解包核对 Debian `Version`、App `CFBundleShortVersionString`、签名及哈希。
   包内不得包含 StressWatch 观察器、客户端兼容实验、设备日志、SSH 凭据或私有诊断。
7. **覆盖安装与桌面注册分别验收。** 用 `dpkg -i <已核验的.deb>` 覆盖安装，不先卸载或删数据。
   本轮旧隐藏备份 `.WatchFix-module-test-original.app` 与新 App 使用相同 bundle ID，曾在安装后
   重新抢占桌面注册；因此 dpkg 成功不等于点击图标运行新版本。检查注册的实际路径和运行版本；
   必要时仅注销旧备份的注册，再定向注册新 App，保留备份文件。不使用全量缓存清理/respring
   替代检查，不重启 healthd 或重新执行同步来验收 App 升级。

### 本次可用测试包

- Debian Version：`2.0.12~sleepsync3-1+debug`，RootHide / `iphoneos-arm64e`。
- SHA256：`cb0d023b92c3593735ecc90e478b3d67a9d77eff7be260b0c0547f4e1a96f104`。
- 这是**单设备品牌绑定的工程测试包**，不是所有 iOS 15.4 设备都可用的通用正式版。
- 健康 App 睡眠显示已获用户反馈；StressWatch 仍无数据。仅更新 WatchFix 包不替代 HealthSupport
  Runtime 的独立加载和功能验收。本轮升级没有重启 healthd，也没有发起睡眠配置同步。

### StressWatch 低开销兼容开关（2026-11-26）

新增 `Modules/HealthSupport/StressWatch` 附属运行库，经“睡眠阶段支持”的
模块设置独立开启/关闭；不属于 SleepSync（睡眠配置同步），不解锁 Pro。
默认关闭，检测到独立 v1.3 时提供保存迁移；切换后保存并彻底重开 StressWatch。
不会为切换此开关而重启 healthd，不移除已存阶段的读取保护。

与已验收的独立 v1.3 相比，移除查询观察器、样本计数、JSON 回执、计时窗口
和两次整包哈希，只保留启动身份/关键代码检查及两个兼容点。低开销并非零
开销；精确适用当前已核对的 StressWatch 镜像，其他版本拒绝启用。

`2.0.12~healthsupport2-1+debug` 是本次单设备测试包；App/模块编译、归档完整性
和本机开关/迁移/失败回滚测试已通过。用户已在设置中保存迁移，设备文件核对
确认低开销库接替且旧 v1.3 注入文件移除；随后用户反馈“已测试stresswatch正常”。
这属于用户侧功能验收，尚未测试完整的关闭/重开/再开启流程、下一晚自动更新
或长期功耗。旧 sleepsync3 包的历史限制和哈希不变。
新包 SHA256：`fac6974a58c875f2c41a74f0fa6d74bd577f8f252216b2671dd48a2697fd4484`。
仅包含低开销正式源码附属库，不包含独立观察实验、第三方 Pro 包、设备日志或凭据。

本次源码测试可在 macOS 运行，不需要手机、商业 App 文件或私有诊断副本：
```sh
python3 -B Tests/HealthSupport/test_stresswatch_lowpower.py
python3 -B Tests/HealthSupport/test_stresswatch_installer_host.py
```
后者使用合成 Mach-O 数据及模拟 root 命令测试实际安装器方法，不执行 iOS 代码。
上面的设备绑定 deb 哈希只是历史测试产物记录，不表示当前源码可逐字节复现该包。

## Credits

- **[577fkj/WatchFix](https://github.com/577fkj/WatchFix)**：上游项目与原始功能实现。
- **[WatchPair11](https://github.com/plokijuter/WatchPair11)**: Multiple repair references

## License

遵循上游的 [GPL-3.0 许可证](LICENSE)。
