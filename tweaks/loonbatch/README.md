# LoonBatch

Loon 插件/规则批量管理。包名 `com.tomie.loonbatch`，注入 `com.ruikq.decar`（Loon 3.5.x）。

## 功能

- 在插件列表、本地规则、远程规则和全部规则页加一个「批量」按钮。
- 独立批量页：逐项勾选、全选/全不选，底部工具栏固定不随列表滚动。
- 批量复制链接（本地规则复制规则文本）、启用/禁用、上移/下移、删除。
- 插件标题读取已下载插件文件里的 `#!name`，与原生列表名称一致。
- 插件删除会同时清理该插件生成的规则；删除前备份当前 `.lcf`。
- 列表使用快速减速，长列表滚动更快。

## 入口

- 插件列表：`PluginListSwiftVC` / `PluginListVC`
- 规则列表：`AllRulesVC`
- 本地规则列表：`LNLocalRuleListVC`
- 远程规则列表：`RemoteRuleListVC`

## 实现说明

- 从 `DataManager.shareInstance.currentConfigModel` 读取 `DCConfigModel`。
- 插件来自 `config.plugins`（`LNPlugin`），本地规则来自 `config.localRule`（`Rule`），远程规则来自 `config.remoteRules`（`RemoteRule`）。
- 原生插件名：`MD5(remoteUrl)` 对应 App Group `remotePlugin/<hash>.lpx|.plugin` 里的 `#!name`。
- 删除使用 `RuleArchieveManager.shareInstance` 的 `deletePluginRules:`、`deleteLocalRule:`、`deleteRemoteRule:`，最后调用 `saveConfigPlayload`。
- 调试日志：App 沙盒 `Documents/loonbatch.log`。

## 状态

批量页和各项操作已在真实配置上跑通；Swift 插件页的刷新依赖 `postChangeNoti` 和页面自身刷新方法。
