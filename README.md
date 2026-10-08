# ios-tweaks

自用 iOS 越狱插件集合。每个插件一个独立目录，统一用 GitHub Actions 构建。

> 私有仓库，仅供本人使用。

## 目录结构

```
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

1. `mkdir tweaks/<name>`，放入源码与 `tweak.env`（参考 `tweaks/soul/tweak.env`）。
2. 提交即可，Actions 会自动一起构建。

## 现有插件

- **soul** — SOUL 6.17 助手（`com.soulfx.souldicetweak`），面板按功能分组：
  - 聊天与消息：自定义骰子/猜拳、防撤回（私聊/群聊）、超 2 分钟撤回、禁止上报状态（输入/查看主页）、禁止已读回执、收到消息自动已读、禁止挚友邀请、回前台清除通知
  - 图片/视频/分享：阅后即焚解锁（截屏/多次查看）、保存与分享无水印+无限制、去除主页分享限制、解除选择数量上限
  - 限制与体验：去除送礼限制（聊天/奇遇铃）、去除礼仪分限制、关闭匹配背景音乐、跳过开屏广告、语音消息解锁装扮
  - 调试：调试日志（出站请求日志 + 落盘）

  配置统一存放在 App 沙盒 `Library/Preferences/SoulFX/`（`config.plist` / `soulfx.log` /
  `recall.plist`），不改动原 App 自身配置。旧版键名（`soul_fx_*_v1`）启动时自动迁移。
