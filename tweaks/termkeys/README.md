# TermKeys

给终端类 App 补上 Shift、`NL` 和 F1–F12。系统键盘没有这些键，键盘扩展也传不了真正的修饰键状态，所以插件把按键交给终端自己的按键入口（拿不到时退回 xterm 序列）。

## iGhostVT

按键**加进 iGhostVT 自带的键盘附件栏**（libghostty 的 `TerminalInputAccessoryView`），不另加一层。

这一点是关键：另加一层会把键盘撑高，iOS 15 的键盘避让随后把整窗内容上顶，终端首行压到状态栏下面。加进自带栏以后键盘高度与官方版一致，终端布局和没装插件时完全相同。

栏里依次为：`⇧`、`NL`，然后是原有的 Esc、Tab、Ctrl、Option、Command、方向键等，F1–F12 追加在末尾（自带栏可横向滑动）。

- `⇧`：单击一次生效，0.35 秒内再点一次锁定（右上角白点），再点解除。
- `NL`：发送 Ctrl+J 插入换行，用于 Codex / Claude Code 这类终端 Agent。
- F1–F12：走 Ghostty 原生 `sendKey`，不会被拆成单独的 ESC。

App 更新后重新打开一次即可；插件挂在 `inputAccessoryView` 与栏的重建方法上，不依赖具体版本。

## 其他终端 App

CareServer、Blink、iSH、Termius、Prompt、Secure ShellFish 等没有自带键栏的终端，浮一条两行键栏在键盘上方：第一行 `⇧`、`NL` 靠左、方向键靠右（按住连发），第二行 F1–F12 可横向滑动。

## 安装

- 越狱：deb 的过滤器默认包含 iGhostVT 与上面几个终端 App，其他 App 改 `TermKeysTweak.plist` 后重新打包。
- TrollFools：把 `TermKeys.dylib` 注入目标 App。

## 开关

```
defaults write wiki.qaq.iGhostVT TermKeys.diag -bool NO    # 关诊断日志
```

诊断日志在 App 容器的 `Documents/termkeys-diag.log`。

## 限制

iOS 键盘扩展只能向输入框插入文本，不能把真正的硬件修饰键状态交给宿主 App。本插件因此把 Shift 和 F 键编码成终端序列；它适合 xterm 兼容终端，不能让普通 App 获得 PC 那样的 F 键语义。普通文本 App 的系统键盘本来就有 Shift。
