# TermKeys

给终端类 App 增补一条悬浮在系统键盘上方的按键栏。适合没有 Shift、F1–F12 的终端前端；也可以用 TrollFools 手动注入任选 App。

## 按键

- `⇧`：粘滞 Shift。点一次后高亮，下一次按本键条里的键时生效，然后自动取消。
- `Esc`、`Tab`、`⏎`、`NL`、方向键。
- `F1`–`F12`：按 xterm 的 SS3/CSI 功能键序列发送。Shift 打开时发送带 `;2` 的修改序列。
- `NL` 发送 LF（Ctrl+J），常用于在 Codex / Claude Code 等终端 Agent 中插入换行而不提交。

## 使用

- TrollFools：把构建产物 `TermKeys.dylib` 注入目标 App。注入后可随 App 启动。
- 越狱安装：deb 中的 filter 默认包含 iGhostVT、CareServer、Blink、iSH、Termius、Prompt、Secure ShellFish。其他 App 可改 `TermKeysTweak.plist` 后重新打包。
- iGhostVT 使用官方安装包即可；插件会在同一个 bundle ID 的新版本中继续生效，App 更新后重新打开一次即可。

## 限制

iOS 键盘扩展只能向输入框插入文本，不能把真正的硬件修饰键状态交给宿主 App。本插件因此把 Shift 和 F 键编码成终端序列；它适合 xterm 兼容终端，但不能让任意普通 App 获得 PC 那样的 F 键语义。普通文本 App 的系统键盘本来就有 Shift。
