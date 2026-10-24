# SoulDiceTweak

SOUL 6.17 助手。包名 `com.soulfx.souldicetweak`，注入 `Soul_New`。

## 入口

进入 SOUL 的设置类网页容器后，点右上角的骰子图标打开设置面板。面板按分组分层：先选分组，再在二级页里开关或改文本；点右上角「完成」或点面板外空白处关闭。

## 功能

- 聊天与消息：自定义骰子/猜拳、防撤回（私聊 / 群聊）、超过 2 分钟撤回自己的消息、禁止上报输入/主页状态、禁止已读回执、自动已读、禁止挚友邀请、回前台清通知、去除青少年弹窗。
- 图片 / 视频 / 分享：阅后即焚解锁、无水印保存/分享、去除主页分享限制、解除图片/视频选择数量上限。
- 限制与体验：去除送礼限制、去除礼仪分限制、关闭匹配背景音乐、跳过开屏广告、语音消息解锁装扮。
- 消息时间：每条消息显示发送时间，格式可自定义（NSDateFormatter 格式，默认 `HH:mm`）。
- 调试：可单独打开请求日志落盘。

## 配置

统一放在 App 沙盒 `Library/Preferences/SoulFX/`：

- `config.plist`：功能开关（含 `soulfx_no_teen_popup`、`soulfx_msg_time`、`soulfx_msg_time_format`）
- `soulfx.log`：调试日志（打开调试后才有）
- `recall.plist`：防撤回角标记录
- `skip.txt`：调试跳过分组（新增 `teen`、`msgtime`）

## 已知限制

- 青少年弹窗通过拦截 `SOMainSquareViewController` 的展示入口和 `SOPrivateChatViewController` 的青少年提示实现；服务端强推或其它页面入口若未覆盖，可打开调试日志按 `teen:` 前缀排查后补充。
- 每条消息的时间挂在 `SODCMsgCell` 上，并通过 `SODCMsgLayout.cellHeight` 额外预留 13pt；不同消息类型的视觉位置需要真机确认后再微调。
