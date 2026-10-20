# LoonBatch

Loon 插件/规则批量管理。包名 `com.tomie.loonbatch`，注入 `com.ruikq.decar`（Loon 3.5.3）。

## 功能

- 在插件列表、规则列表页右下角加一个「批量」按钮。
- 打开独立的批量页，按当前配置列出全部插件或规则。
- 支持逐项勾选、全选/全不选、批量删除。
- 插件页删除插件时会同时清理该插件生成的规则。
- 规则页分「本地规则 / 远程规则」两组，分别调用 Loon 的删除接口。
- 删除前会把当前 `.lcf` 备份到 App 沙盒 `Library/Application Support/LoonBatch/`。

## 入口

- 插件列表：`PluginListSwiftVC` / `PluginListVC`
- 规则列表：`AllRulesVC`
- 本地规则列表：`LNLocalRuleListVC`
- 远程规则列表：`RemoteRuleListVC`

每个页面右下角都有「批量」浮动按钮。

## 实现说明

- 从 `DataManager.shareInstance.currentConfigModel` 读取 `DCConfigModel`。
- 插件来自 `config.plugins`（`LNPlugin`），本地规则来自 `config.localRule`（`Rule`），远程规则来自 `config.remoteRules`（`RemoteRule`）。
- 删除使用 `RuleArchieveManager.shareInstance` 的 `deletePluginRules:`、`deleteLocalRule:`、`deleteRemoteRule:`，最后调用 `saveConfigPlayload`。
- 调试日志：App 沙盒 `Documents/loonbatch.log`。

## 状态

首个可用版本，插件列表入口已验证；规则列表和实际删除流程还需要在真实配置上测试。删除前有二次确认和 `.lcf` 备份。
