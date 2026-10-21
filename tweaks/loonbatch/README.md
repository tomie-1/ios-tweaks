# LoonBatch

Loon 插件、规则和节点批量管理。包名 `com.tomie.loonbatch`，注入 `com.ruikq.decar`（Loon 3.5.x）。

## 功能

- 插件列表、总规则页和「所有节点」页右下角提供可拖动的圆形悬浮入口（`checklist` 图标）；策略主页不加入口。
- 悬浮按钮支持单指拖动，位置只在本次 App 进程内保持；重开 Loon 回到默认右下角。
- 批量页从底部以 sheet 弹出，逐项勾选、全选/全不选，底部工具栏固定。
- 双指落下后直接上下拖动可按区间连续选中/取消，反向拖回会撤回区间外的选择；单指仍用于滚动、点按和长按排序。
- 操作菜单：复制、启用/禁用、删除；插件启用/禁用和拖动排序使用轻量保存，不触发全量插件更新。
- 删除成功后批量页保持打开并刷新列表，可继续操作。
- 长按拖动排序；勾选多行后拖动其中一行会整组移动，落点线在手指移动后出现。
- 插件标题优先读取 Loon 配置中的 `tag`，没有 tag 时依次用 `pluginName`、文件名；副标题显示插件链接。
- 插件、远程规则、远程订阅用右侧状态胶囊显示启用状态，勾选独立显示。
- 插件删除会同时清理该插件生成的规则，并修复配置里可能残留或重复的插件行；删除前备份当前 `.lcf`。

## 入口

- 插件列表：`PluginListSwiftVC` / `PluginListVC`
- 总规则页：`AllRulesVC`（本地规则和远程规则都在这里批量操作，子页不重复加入口）
- 所有节点页：`PolicyGroupSelectVC`，仅独立页面；策略主页中嵌入的实例不加入口

## 实现说明

- 从 `DataManager.shareInstance.currentConfigModel` 读取 `DCConfigModel`；节点页优先读页面的 `configModel`。
- 插件来自 `config.plugins`，规则来自 `config.localRule` / `config.remoteRules`，节点来自 `config.proxys` / `config.remoteProxys`。
- 插件原生标题：配置 `tag` → `LNPlugin.pluginName` → 下载文件里的 `#!name`。
- 节点删除使用 `DCConfigModel` 的 `deleteNode:` / `deleteRemoteProxy:`，规则删除使用 `RuleArchieveManager` 的对应接口。
- 拖动只会在同一个分组（分组 kind）内排序。
- 调试日志：App 沙盒 `Documents/loonbatch.log`。

## 状态

插件、规则、节点三类的批量选择、启停、拖动排序、复制和删除已在真实配置上跑通。
