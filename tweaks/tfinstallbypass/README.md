# TFInstallBypass（实验性，已停用）

状态：实验性，未验证，已从设备卸载。源码保留。

作用：注入 `installd`，hook `MIBundle` 的以下检查：

- `isApplicableToCurrentDeviceFamilyWithError:`
- `isApplicableToCurrentDeviceCapabilitiesWithError:`
- `isMinimumOSVersion:applicableToOSVersion:error:`
- `isApplicableToCurrentOSVersionWithError:`
- `isApplicableToOSVersion:error:`
- `isCompatibleWithDeviceFamily:`
- `thinningMatchesCurrentDeviceWithError:`

只有标记文件存在时才放行，默认关闭。

已知问题 / 待优化：

- 测试期间没有生成 `TFInstallBypass.log`，无法确认 tweak 是否成功注入 `installd`。
- 签名放行依赖设备上已有的 AppSync，本插件不处理签名。
- 放行后应用可能安装成功但无法启动；没有逐项验证。
- 需要补一个可靠的开关入口和注入状态检查。

标记文件路径（已删除）：

`/var/mobile/Library/Preferences/com.tomie.tfinstallbypass.enabled`
