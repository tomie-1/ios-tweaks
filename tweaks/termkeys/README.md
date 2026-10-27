# TermKeys

给终端类 App 补上 Shift、`NL`、方向键和 F1–F12。系统键盘没有这些键，键盘扩展也传不了真正的修饰键状态，所以插件把按键交给终端自己的按键入口（拿不到时退回 xterm 序列）。

## 布局

一条两行键栏浮在系统键盘之上，**不并入 `inputAccessoryView`**。

- 第一行固定不滚动：`⇧`、`NL` 靠左，方向键靠右（按住连发）。
- 第二行只放 `F1`–`F12`，可横向滑动。

不并入附件栏是有原因的：附件栏一旦变高，键盘总高度随之变大，iOS 15 的键盘避让会把整窗内容上顶，终端首行压到状态栏下面。所以键栏改成独立的浮层，终端用根视图的 `additionalSafeAreaInsets` 精确让出这块高度——键盘高度不变，布局不会被顶。

## iGhostVT

App 自带的附件栏一个按键都不改，只在它上面挂一层 Shift 拦截器：Shift 亮着时点原生 Tab／Esc／方向键，改由插件发带 Shift 的原生按键。

这不是可有可无的补丁——libghostty 的粘滞修饰键只有 Ctrl／Alt／Cmd，它的 `Modifier` 枚举里根本没有 Shift，自带栏的按键读的是它自己的状态机。不拦截的话，Shift 亮着按 Tab 只会发出普通 Tab，而 Shift 也不会熄灭。

拦截器只在「Shift 亮着 + 落点是这几个键 + 手指没移动」时才接管，其余情况一律放行，横向滑动不受影响。

- `⇧`：单击一次生效，0.3 秒内再点一次锁定（右上角白点），再点解除。
- `NL`：发送 Ctrl+J 插入换行，用于 Codex / Claude Code 这类终端 Agent。
- F1–F12：走 Ghostty 原生 `sendKey`，不会被拆成单独的 ESC。

## 安装

- 越狱：deb 的过滤器默认包含 iGhostVT、CareServer、Blink、iSH、Termius、Prompt、Secure ShellFish，其他 App 改 `TermKeysTweak.plist` 后重新打包。
- TrollFools：把 `TermKeys.dylib` 注入目标 App。

## 开关

```
defaults write wiki.qaq.iGhostVT TermKeys.diag -bool NO    # 关诊断日志
```

诊断日志在 App 容器的 `Documents/termkeys-diag.log`。

## 限制

iOS 键盘扩展只能向输入框插入文本，不能把真正的硬件修饰键状态交给宿主 App。本插件因此把 Shift 和 F 键编码成终端序列；它适合 xterm 兼容终端，不能让普通 App 获得 PC 那样的 F 键语义。普通文本 App 的系统键盘本来就有 Shift。
