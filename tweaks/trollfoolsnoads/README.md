# TrollFoolsNoAds

TrollFools 去广告。包名 `com.tomie.trollfoolsnoads`，注入 `wiki.qaq.TrollFools`。

## 功能

- 接管 TrollFools 的 `@AppStorage("isAdvertisementHiddenV2")`。
- 读取恒为 `YES`，写入也强制写成 `YES`，应用列表里的推广卡片不再出现。
- 官方版和修改版共用同一个键，一份 dylib 通用。

## 说明

- 不需要配置；安装后重启 TrollFools 生效。
