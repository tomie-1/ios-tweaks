# ios-tweaks

自用 iOS 越狱插件集合，每个插件一个独立目录，统一用 GitHub Actions 构建。

## 插件

| 目录 | 包名 | 说明 | 状态 |
|---|---|---|---|
| [souldicetweak](tweaks/souldicetweak/README.md) | `com.soulfx.souldicetweak` | SOUL 6.17 助手 | 自用 |
| [tftool](tweaks/tftool/README.md) | `com.tomie.tftool` | TestFlight 批量停止测试 | 自用 |
| [trollfoolsnoads](tweaks/trollfoolsnoads/README.md) | `com.tomie.trollfoolsnoads` | TrollFools 去广告 | 自用 |
| [tfdevices](tweaks/tfdevices/README.md) | `com.tomie.tfdevices` | TestFlight 设备伪装 | 实验性，已停用 |
| [tfinstallbypass](tweaks/tfinstallbypass/README.md) | `com.tomie.tfinstallbypass` | installd 兼容性放行 | 实验性，已停用 |
| [loonbatch](tweaks/loonbatch/README.md) | `com.tomie.loonbatch` | Loon 插件/规则/节点批量管理 | 自用 |
| [termkeys](tweaks/termkeys/README.md) | `com.tomie.termkeys` | 终端类 App 补 Shift、NL、F1–F12（iGhostVT 加进自带键栏，不改布局） | 自用 |

功能、入口和已知问题见各插件目录下的 `README.md`。

## 构建

推送到 `main` 或手动触发 `workflow_dispatch`，Actions 会自动构建；打 tag 会额外发布 Release。

每个插件输出 dylib 和三种 deb：rootful（`iphoneos-arm`）、rootless（`iphoneos-arm64`）、roothide（`iphoneos-arm64e`）。

## 新增插件

1. `mkdir tweaks/<name>`，放入源码、`tweak.env` 和可选的注入过滤器。
2. 补一份该目录的 `README.md`。
3. 提交即可，Actions 会自动构建。
