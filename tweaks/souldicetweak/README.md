# SoulDiceTweak

SOUL 6.17 助手。包名 `com.soulfx.souldicetweak`，注入 `Soul_New`。

## 入口

启动后屏幕右侧会出现一个可拖动的悬浮图标，点它打开设置面板；也可以长按底部「自己」标签打开。面板按分组分层：先选分组，再在二级页里开关或选格式；点右上角「完成」或点面板外空白处关闭。悬浮图标位置会记住。

## 功能

- 聊天与消息：自定义骰子/猜拳、防撤回（私聊 / 群聊）、超过 2 分钟撤回自己的消息、禁止上报输入/主页状态、禁止已读回执、自动已读、禁止挚友邀请、回前台清通知、去除青少年弹窗、截图不提醒对方、语音消息自动转文字、长按菜单增强（复制文本 / 复制转写 / 保存语音）。
- 图片 / 视频 / 分享：阅后即焚解锁、无水印保存/分享、去除主页分享限制、解除图片/视频选择数量上限。
- 限制与体验：去除送礼限制、去除礼仪分限制、关闭匹配背景音乐、跳过开屏广告、语音消息解锁装扮、去除广告（信息流 / 推荐 / 评论 / 搜索 / 群聊 / 横幅）。
- 消息时间：每条消息显示发送时间，格式从常用预设里点选（`HH:mm`、`HH:mm:ss`、`MM-dd HH:mm` 等，默认 `HH:mm`）。
- 调试：可单独打开请求日志落盘。

## 配置

统一放在 App 沙盒 `Library/Preferences/SoulFX/`：

- `config.plist`：功能开关（含 `soulfx_no_teen_popup`、`soulfx_msg_time`、`soulfx_msg_time_format`）
- `soulfx.log`：调试日志（打开调试后才有）
- `recall.plist`：防撤回角标记录
- `skip.txt`：调试跳过分组（新增 `teen`、`msgtime`、`autovoice`、`screenshot`、`ads`）

## 已知限制

- 青少年弹窗通过拦截 `SOMainSquareViewController` 的展示入口和 `SOPrivateChatViewController` 的青少年提示实现；服务端强推或其它页面入口若未覆盖，可打开调试日志按 `teen:` 前缀排查后补充。
- 系统启动图在进程起来前由 iOS 绘制（`Assets.car` 的 `launch_launchImage`），dylib 无法修改或跳过。
- 语音转文字复用 `SOChatAudioMessageTableViewCell` 自带的转写按钮，群聊语音 cell 没有该按钮，暂不自动转写。
- 去广告拦截的是信息流/推荐/评论/搜索/群聊的广告开关和横幅视图；开屏广告仍由原有「跳过开屏广告」单独控制。
- 每条消息的时间挂在 `SODCMsgCell` 上，并通过 `SODCMsgLayout.cellHeight` 额外预留 13pt；不同消息类型的视觉位置需要真机确认后再微调。
