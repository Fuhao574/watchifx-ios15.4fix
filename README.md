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

### 尚未实现

- Health Support

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

## Credits

- **[577fkj/WatchFix](https://github.com/577fkj/WatchFix)**：上游项目与原始功能实现。
- **[WatchPair11](https://github.com/plokijuter/WatchPair11)**: Multiple repair references

## License

遵循上游的 [GPL-3.0 许可证](LICENSE)。
