# ios-repo

tomie 的 iOS 越狱源（flat APT repository）。

## 目录结构

```
.
├── Packages / Packages.gz / Packages.xz   # 包索引（自动生成）
├── Release                                # 源元数据（自动生成）
├── debs/<arch>/*.deb                      # 收录的 deb
├── depictions/                            # Sileo depiction（可选）
├── CydiaIcon.png                          # 源图标（可选）
└── scripts/build_repo.sh                  # 索引生成器
```

## 重新生成索引

```bash
bash scripts/build_repo.sh .
```

把 deb 丢进 `debs/<arch>/` 后跑一次即可，会重写 `Packages` / `Packages.gz` / `Packages.xz` / `Release`。

## 添加源

```
<公开后的地址>
```

> 注意：Sileo / Zebra 无法携带鉴权，**私有库不能直接作为源**。
> 要真正在包管理器里用，需要把本库设为 public，或启用 GitHub Pages（Pro/Team）。

## 架构说明

| deb Architecture | 安装路径 | 适用 |
|---|---|---|
| `iphoneos-arm` | `/Library/MobileSubstrate/DynamicLibraries` | rootful（unc0ver/checkra1n） |
| `iphoneos-arm64` | `/var/jb/Library/MobileSubstrate/DynamicLibraries` | rootless（Dopamine 等） |
| `iphoneos-arm64e` | `/Library/MobileSubstrate/DynamicLibraries`（jbroot 相对） | roothide |

dylib 本体是同一个文件，差异只在安装路径与架构标记。

## 收录

| 包 | 说明 |
|---|---|
| `com.tomie.trollfoolsnoads` | TrollFools 去广告（官方/修改版通用） |
| `com.soulfx.souldicetweak` | SOUL 助手 |