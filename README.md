# ios-tweaks

自用 iOS 越狱插件集合。每个插件一个独立目录，统一用 GitHub Actions 构建。

> 私有仓库，仅供本人使用。

## 目录结构

```
# 目录名统一为“包名最后一段”，例如 tweaks/tftool ↔ com.tomie.tftool
tweaks/<name>/
  tweak.env            插件配置（名字 / 包名 / 源文件 / 过滤器 ...）
  *.m                  源码（纯 Objective-C 运行时 hook）
  *.plist              注入过滤器（可选）
scripts/build_tweak.sh 通用构建脚本
.github/workflows/build.yml
```

## 构建

推送到 `main` 或手动触发 `workflow_dispatch`，Actions 会自动构建并上传产物；
打 tag（如 `v1.0.0`）会额外发布 Release。

产物（`dist/`）：

| 文件 | 说明 |
|---|---|
| `<name>.dylib` | 注入用 / deb 内同一份 |
| `<pkg>_iphoneos-arm.deb` | rootful，装 `/Library/MobileSubstrate/DynamicLibraries/` |
| `<pkg>_iphoneos-arm64.deb` | rootless，装 `/var/jb/Library/MobileSubstrate/DynamicLibraries/` |
| `<pkg>_iphoneos-arm64e.deb` | roothide，装 `/Library/MobileSubstrate/DynamicLibraries/` |

## 新增插件

1. `mkdir tweaks/<name>`，放入源码与 `tweak.env`（参考 `tweaks/souldicetweak/tweak.env`）。
2. 提交即可，Actions 会自动一起构建。

## 现有插件

- **souldicetweak** — SOUL 6.17 助手（`com.soulfx.souldicetweak`）：自定义骰子/猜拳、防撤回、无水印保存、去掉送礼与礼仪分等限制，配置存在 App 沙盒 `Library/Preferences/SoulFX/`。
- **trollfoolsnoads** — TrollFools 去广告（`com.tomie.trollfoolsnoads`）：接管 `isAdvertisementHiddenV2`，应用列表里的推广卡片不再出现（官方版/修改版通用）。
- **tftool** — TestFlight 批量「停止测试」（`com.tomie.tftool`）：在 TestFlight 里多选后一次性停掉多个 App 的测试，并标出每个 App 装的是测试版还是正式版。
- **tfdevices** — TestFlight 设备伪装（`com.tomie.tfdevices`）：可切成 iPad / Apple TV / Mac 的机型与系统信息，并管理账号下的测试设备。
- **tfinstallbypass** — 安装兼容性放行（`com.tomie.tfinstallbypass`）：默认关闭，存在标记文件时让 installd 跳过最低系统版本和设备家族检查。
