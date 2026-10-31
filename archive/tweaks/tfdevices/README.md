# TFDevices（实验性，已停用）

状态：实验性，功能不完整，暂不继续维护。设备上的 deb 已卸载，源码保留。

已验证：

- iPad / Apple TV / macOS 预设能改 `TFCurrentDevice` 的 `productType`、`model`、`systemVersion`、`buildVersion`、`platformName`、`OS` 等字段。
- Apple TV 预设下，TestFlight 请求头 `X-Apple-Device-Model` 会变成 `AppleTV14,1`；App 列表能看到 tvOS 版 Clash、Loon、Quantumult X、AptvPlayer 等。
- 通知开关会向 `/v1/accounts/settings/notifications/apps/<id>` 发 POST；日志只能看到请求，未记录服务器响应。

已知问题 / 待优化：

- `User-Agent` 仍是 `iPhone14,3 / iOS/15.5 / build/19F77`，和伪造的机型不一致，服务器可能据此二次校验。
- 没有验证 tvOS / macOS 应用能否真正下载、安装、启动；安装阶段仍受 `installd` 校验影响。
- 只 hook 了 `TFCurrentDevice` 和部分 `TFAppBuild` 安装资格字段，没有完整处理 build 兼容状态和安装 precheck。
- 账号设备列表在部分网络/账号下仍可能取不到。
- macOS 伪装可能让 TestFlight UI 行为异常，未系统测试。
- 调试日志和实验性 hook 仍在源码里，正式使用前需要清理。

配置位置（已随卸载删除）：

- App 沙盒 `Documents/tfspoof.plist`
- 调试日志 `Documents/tfdevices.log`
