# TFTool

TestFlight 批量「停止测试」。包名 `com.tomie.tftool`，注入 `com.apple.TestFlight`。

## 功能

- 在 TestFlight 顶部「兑换」旁放一个入口按钮，从底部弹出多选 sheet。
- 点按选中；长按后上下拖动可按区间批量选中/取消，拖到列表边缘会自动滚动。拖动期间会临时禁用 sheet 下拉手势，避免半高状态下弹动。
- 底部固定工具栏：全选/全不选、已选数量、停止测试；顶部保留刷新和取消。
- 「停止测试」调用 TestFlight 自己的退订接口；选中 5 个以上或全选时会二次确认。
- 每个 App 右侧标出是否已安装，以及装的是「测试版 / 正式版」。

## 说明

- 使用 TestFlight 内部对象 `OASAppList`、`OASAppContext`、`OASInviteManager`，不直接拼服务器请求。
- 已在 TestFlight 3.5.2 上验证。
- 调试日志：App 沙盒 `Documents/tftool.log`。
