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

- **tftool** — TestFlight 批量「停止测试」（`com.tomie.tftool`）：
  - 入口：TestFlight 列表页顶部、原生「兑换」按钮左边的蓝色「批量」（位置按无障碍树取到的「兑换」frame 对齐）；
  - 多选：点击单行勾选；**长按后拖动连续多选**（锚点区间模型：按住那行决定这一笔是「选」还是「取消」，往回滑区间缩小会撤销刚选上的，滑过锚点继续走则反向继续；拖到列表上下边缘自动滚动）；顶栏 `全选/全不选`、`⟳ 刷新`、`取消`（清空勾选），`停止测试` 在勾选 ≥5 或全选时二次确认；中间标题显示 `已选 N 个`；
  - 数据、分组、图标、文案全部取自 TestFlight 自己：`OASAppList`（列表，条目是 `TFApp`）、`OASAppListSection.sectionType` 位标志 + `OASLocalizable`（分组标题）、`OASIconURLImageView` + `TFApp.latestAppBuild`（图标，走它自己的图标服务与缓存）；
  - 执行走 App 自己的入口：`[[OASAppContext alloc] initWithAppStub:app andSessionContext:list.sessionContext]` → `-unsubscribeWithCompletion:`（内部即 `OASInviteManager -unsubscribeFromApp:withCompletion:`，与手动点详情页「停止测试」同一条路径）；
  - 状态气泡：绿色 `测试版`（`OASAppContext.installedBuildGroupOrVersion` 有值）、灰色 `正式版`（`LSApplicationWorkspace` 里有但没装测试版）；
  - 所有私有类/selector 都做了存在性检查，TestFlight 升级后最坏是**静默失效而非崩溃**。
