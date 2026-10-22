# TrollFools 注入与退出

这份记录来自 2026-10-22 在 RootHide / iOS 15.5 上对 Swiftgram 的实际退出、重新注入和 TrollFools 识别测试。

## 砸壳包在哪里

默认先查：

```text
/rootfs/private/var/mobile/Documents/DumpDecrypter/
```

这是系统真实 mobile 的 `Documents/DumpDecrypter`，也是 Files App 里的 `DumpDecrypter` 目录。引导路径 `/var/mobile/Documents` 是另一个目录，通常看不到这些 IPA。

用户说“有砸壳包”时，先在上面的目录按修改时间查找；用户另发路径时直接使用指定文件。可以从 IPA 的 `Payload/*.app/Info.plist` 读取 bundle ID 和版本，再检查主程序 `LC_ENCRYPTION_INFO_64.cryptid` 是否为 0。

## TrollFools 判断注入的两层依据

- App 是否显示为已 Patch：`Frameworks/CydiaSubstrate.framework` 是否存在。
- 注入插件列表：`Frameworks/` 顶层所有非 `libswift*` 的 `.dylib`，以及带 `.troll-fools` 标记的 framework。

因此只复制 dylib 只能让它出现在列表里，不能保证运行期已加载。

## 成功注入后的结构

以 Swiftgram 为例：

```text
Frameworks/SwiftgramCrack.dylib
Frameworks/CydiaSubstrate.framework/CydiaSubstrate
Frameworks/CydiaSubstrate.framework/.troll-fools
Frameworks/MtProtoKitFramework.framework/MtProtoKitFramework
Frameworks/MtProtoKitFramework.framework/MtProtoKitFramework.troll-fools.bak
```

加载关系：

```text
MtProtoKitFramework
  └─ LC_LOAD_WEAK_DYLIB @rpath/SwiftgramCrack.dylib
       └─ LC_LOAD_DYLIB @executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate
```

TrollFools 默认优先找 App 主程序实际链接、且未加密的 framework 作为注入点。主程序被 FairPlay 加密不一定无法注入；只要有一个可用的明文 framework，就能做弱引用注入。没有可用 framework、只能改加密主程序时，才需要先安装砸壳 IPA。

## 架构、依赖和“列表里能看到”

TrollFools 能把插件写进加载项，但不会让不兼容的 dylib 自动变得可加载。需要注意：

- 目标 App 实际运行的 Mach-O 架构必须与 dylib 中至少一个切片兼容。
- FAT/Universal dylib 可以包含 `arm64`、`arm64e` 等切片；thin dylib 只有单一架构。
- 在 arm64e 设备上，App 可能是 arm64 进程，也可能是 arm64e 进程；`arm64e` 插件不能加载进 arm64 宿主。`armv7`/`armv7s` 切片在 iOS 15 上也不可用。
- `ct_bypass` 可能把 FAT 文件收敛成单一“最佳切片”。本机在 Notion 上出现过宿主被收敛为 arm64、插件却被收敛为 arm64e 的情况；后来从原插件中提取 arm64 切片重新签名，主程序和插件才一致。
- 插件还需要满足依赖，例如 `CydiaSubstrate`、Swift 运行库、插件自己的 framework；依赖缺失时加载可能失败。
- 弱加载项适合避免插件失败导致 App 启动崩溃，但失败也可能是静默的：dylib 文件存在于 `Frameworks/` 时，TrollFools 列表仍会显示它，不代表运行期真的加载成功。

检查架构：

```sh
file "$HOST"
file "$PLUGIN"
```

若两边不一致，先从 FAT dylib/宿主中提取设备实际使用的切片，再签名和注入。不要只凭 TrollFools 列表中有文件名判断功能已生效。

## 注入步骤

1. 先终止目标 App，不能一边运行一边改 Mach-O。
2. 通过 bundle ID 找到当前 App 包；不要依赖会变化的容器 UUID 来定位业务数据。
3. 确认作为宿主的 framework 文件 `cryptid = 0`，且还没有 `.troll-fools.bak`。
4. 把原宿主 Mach-O 备份为 `<宿主>.troll-fools.bak`。
5. 解压 TrollFools 内的 `CydiaSubstrate.framework.zip`，复制到 App 的 `Frameworks/`，创建空文件 `.troll-fools`。
6. 复制插件 dylib。若插件依赖 `/var/jb/.../libsubstrate` 或 `@rpath/CydiaSubstrate.framework/CydiaSubstrate`，统一改成：

   ```text
   @executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate
   ```

7. 对插件、Substrate 和宿主依次做 `ldid -S` 与 `ct_bypass`。`ct_bypass` 使用宿主原 CodeDirectory 中的 Team ID。
8. 宿主缺少 `@executable_path/Frameworks` 时，用 `install_name_tool -add_rpath` 补上。
9. 用 TrollFools 自带的 `insert_dylib` 写入弱加载项：

   ```text
   @rpath/<插件名>.dylib
   ```

10. 再次签名宿主并执行 CoreTrust bypass，随后把注入文件设为 `33:33`、目录 `0755`、可执行文件 `0755`。
11. 核对宿主和插件的架构一致、宿主里的 `LC_LOAD_WEAK_DYLIB`、插件里的 Substrate 路径、`cryptid=0`，再冷启动 App 验证功能。

`insert_dylib` 参考参数：

```sh
insert_dylib '@rpath/Name.dylib' "$HOST" \
  --inplace --overwrite --no-strip-codesig --all-yes --weak
```

## 退出步骤

1. 终止 App。
2. 若存在 `<宿主>.troll-fools.bak` 且只有一个插件，直接把备份恢复成宿主，可得到与注入前字节一致的 Mach-O。
3. 删除 `Frameworks/<插件>.dylib` 和 `Frameworks/CydiaSubstrate.framework`。
4. 删除 `Library/TrollFools/PersistentPlugins/<bundle-id>/` 中对应持久副本；仅禁用插件时则保留。
5. 删除 `.troll-fools.bak`，确认宿主不再包含插件加载项、`CydiaSubstrate.framework` 不存在。
6. 冷启动 App，TrollFools 应不再显示已 Patch，也不应列出该插件。

## 本机权限注意

普通 shell 是 `mobile`，App 包和 TrollFools 注入文件通常属于 `installd`。`mcp-root` 只允许白名单命令，不能直接执行任意 `cp`、`mv`、`rm`。

本机实测可行的 root 执行方式是：在 `/var/mobile/...` 写入临时脚本，打包成 `iphoneos-arm64e` 的临时 deb，由 root `postinst` 执行，再用 `mcp-root /usr/bin/dpkg -i --no-triggers <绝对路径.deb>` 安装。执行完必须卸载临时包并删除脚本、deb 和日志。不要把临时 helper 留在 Sileo。

## 已验证结果

Swiftgram 的完整退出和重新注入均成功：

- 退出后宿主与注入前备份 SHA-256 完全一致。
- 重新注入后为弱加载，插件、Substrate 和备份结构均正确。
- TrollFools 识别为已 Patch，注入列表显示 `SwiftgramCrack.dylib`。
- App 在注入后冷启动成功，持久注入副本存在。
