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

- **soul** — SOUL 6.17 助手（`com.soulfx.souldicetweak`）：自定义骰子/猜拳、阅后即焚处理、
  去水印/去分享限制、防撤回、超 2 分钟撤回、自动签到/任务等。
