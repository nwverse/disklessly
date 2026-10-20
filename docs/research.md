# Mac 无盘：可行性调研（2026-10-19）

> 结论先说：**可行，但不要做“透明的网络文件系统里直接跑 .app”**。MVP 推荐：**把每个 App 打成只读压缩 DMG，存进 iCloud Drive；/Applications 里放一个自签名的轻量 Stub.app，点击后按需下载、校验、挂载（只读、不进 Finder），再启动真 App，退出后卸载，按 LRU 淘汰**。兼容不了“挂载模式”的 App 走“临时还原到 /Applications”模式。NAS 和 OpenList 放到第二阶段。

---

## 1. “Strata”是什么，“存储版 Strata”指什么

- 检索结果里**没有叫 Strata 的 macOS 应用虚拟化或容器产品**。同名的有三个：
  1. **Niko1221/Strata**：本地大模型引擎，有 macOS 版（Apple Silicon、macOS 15+）。它的核心思路是**模型常驻 SSD，MoE 专家按需从 SSD 流式读入内存（`--mmap-experts`）**，不把整个模型一次性装进内存。2026-10-19 发布了 0.2.0-beta。([releases](https://github.com/Niko1221/Strata/releases), [MAC.md](https://github.com/Niko1221/Strata/blob/main/docs/MAC.md))
  2. **Strata Mac 清理工具**：一个磁盘空间分析和清理 App。([stratamaccleaner.com](https://stratamaccleaner.com/docs/install))
  3. 一个天文图像堆栈 App，和本项目无关。
- **我理解的“存储版 Strata”**（参照第 1 个）：Strata 把“内存 ↔ SSD”做成按需分层加载，本项目把**“本地磁盘 ↔ NAS/云盘”**做成同样的分层。App 平时只在远端存一份，本地只留图标和入口，用的时候才拉下来挂载运行，不用了就淘汰。**这一点需要你确认是不是指这个 Strata。**

## 2. 方案对比

| 方案 | 省空间 | 首次启动 | 签名/Gatekeeper/TCC | 离线 | 复杂度 | iCloud 适配 | 结论 |
|---|---|---|---|---|---|---|---|
| A. 只读 DMG/ASIF 镜像，远端存放，按需挂载 | 高（压缩后约为原大小的 50–70%） | 要先整包拉下来（iCloud 只能整文件下载） | ✅ 签名完整保留，bundle 内容一字节不改 | 预取或固定后可离线 | 低 | ✅ 单个大文件，最适合 | **MVP 主方案** |
| B. 原始 .app 直接放 iCloud Drive / File Provider | 高 | 逐个文件按需物化，冷启动卡顿，可能超时 | ❌ 有风险：符号链接、xattr、执行位、部分物化都可能破坏签名 | 差 | 低 | ❌ Apple 不建议把 App 放进 iCloud Drive | 不采用 |
| C. 符号链接或 Contents 链接（/Applications/Foo.app → 远端） | 高 | 取决于底层挂载 | 签名本身有效；但 Spotlight/Launchpad 不认符号链接；自动更新器会顺着链接改坏远端那份 | 差 | 很低 | ❌ | 不采用（AppPorts 已经弃用 Contents 链接方案） |
| D. Stub + 临时还原（ditto 回 /Applications，用完删除） | 中（运行期间占全量） | 要拉取并解包 | ✅ 和本地安装完全一样，兼容性最好 | 好 | 低 | ✅ | **MVP 兜底模式** |
| E. 自研懒加载文件系统（macFUSE 或 FSKit） | 高，可以按块按需拉 | 最快（按需读取） | 一般可行，但卷属于“非本地”，部分 App 和检查行为不确定 | 要自建块缓存 | 高 | 要自己对接云端 | v3 再考虑 |
| F. rclone mount 或 SMB/NFS 直接跑 .app | 高 | 视网络而定 | 能跑；但网络卷上的 LaunchServices 和 Spotlight 表现不稳定，断网时 App 会卡死或崩溃 | 差 | 低 | ❌ | 只当传输层用 |

### 2.1 DMG、sparsebundle 和本地缓存
- **格式**：分发用 `hdiutil create -srcfolder Foo.app -fs APFS -format ULMO`（LZMA 压缩、只读、UDIF 自带校验和），或 ULFO（LZFSE，解压更快）。sparsebundle（UDSB，默认 8MB 一个 band）适合需要写入或做增量同步的场景，放在云盘里会变成几百上千个小文件，同步和冲突风险都会增加。**只读 App 镜像用单文件 DMG 更合适**。([sparse bundle 性能](https://eclecticlight.co/2024/12/16/are-sparse-bundles-faster-than-disk-images/), [band 大小](https://eclecticlight.co/2020/06/18/selecting-sizes-for-sparse-bundles/))
- **挂载**：`hdiutil attach -readonly -nobrowse -noautoopen -mountpoint ~/.wupan/mnt/<id>`。个别 App 一定要写自己的 bundle，可以加 `-shadow <本机文件>`，写入会落到本地影子文件，而且每台 Mac 必须用各自的影子文件。([多机 + shadow](https://apple.stackexchange.com/questions/144814))
- **经 SMB/WebDAV 直接挂远端 DMG**：SMB 下能用，但启动时的随机读要走网络，而且休眠或断网会让卷失效（常见报错 “Resource temporarily unavailable”）。WebDAV（macOS 自带的 webdavfs）性能差。**建议始终先把整个镜像拉到本地缓存再挂载**，远端只作为仓库。
- **本地缓存**：`~/Library/Caches/Wupan/images/`，设容量上限，按 LRU 淘汰，支持固定（pin）。这台机器的 iCloud Drive 和缓存都在同一个 APFS 卷上，可以用 `cp -c`（APFS clone）实现“零拷贝缓存”，然后再把 iCloud 里的原件 evict 掉。**clone 在原件被 evict 后是否还保留数据，需要实测**。
- 另一个选择是 macOS 26 的 ASIF 格式。macOS 27 新增的 DiskImageKit 主要面向虚拟化，暂时不需要。

### 2.2 File Provider 和 iCloud Drive（MVP 首选后端，下面展开）
- Sonoma 起，iCloud Drive 基于 FileProvider 和 APFS **dataless 文件**实现：元数据在本地，数据不在本地，读取时隐式从网络拉取。打开“优化 Mac 储存空间”后为非复制模式，可以 evict；关闭后为复制模式，所有文件都常驻本地，不能 evict。([eclecticlight](https://eclecticlight.co/2024/03/11/icloud-drive-in-sonoma-optimise-mac-storage-or-not/), [arXiv 2602.19433](https://arxiv.org/html/2602.19433))
- **.app 放 iCloud Drive**：iCloud 按单个文件同步，bundle 内部可能出现“部分 dataless”，冷启动时会触发几千次小文件物化。社区普遍建议不要把 App 或 bundle 放进 iCloud。**直接从 iCloud 启动 .app 不可靠，不采用。**
- **DMG 放 iCloud Drive**：✅ 可行。单文件不超过 **50GB**（超过的文件 iCloud 标记为 Ineligible）。对 evict 状态的 DMG 执行 attach，读取会触发**整个文件下载**，所以等价于“先下载再挂载”；挂载前最好主动下载并显示进度。([Apple](https://support.apple.com/guide/mac-help/check-icloud-drive-file-folder-status-mac-mchlc994344b/mac))
- **可编程控制**：
  - 下载：`FileManager.startDownloadingUbiquitousItem(at:)` 或 `brctl download <path>`；通过 `URLResourceValues.ubiquitousItemDownloadingStatus` 或 `NSMetadataQuery` 看进度。
  - 释放：`FileManager.evictUbiquitousItem(at:)` 或 `brctl evict <path>`。
  - 固定：Sequoia 起 Finder 提供“保持下载”(Keep Downloaded)，固定后系统不会自动 evict。([eclecticlight](https://eclecticlight.co/2024/09/16/sequoia-introduces-pinning-to-icloud-drive/))
  - 我们的工具不上架、不沙盒，按理可以直接对 `~/Library/Mobile Documents/com~apple~CloudDocs/` 下的路径调用这些 API，**需要实测确认**。
- **冲突**：两台 Mac 同时写同一个文件会产生 “xxx 2.dmg” 冲突副本。对策是**镜像不可变**（文件名为 `<bundleid>-<ver>-<sha8>.dmg`），只追加新版本；索引 manifest 每台机器只写自己的部分，或者用 CRDT/追加日志。
- **限制**：iCloud 容量受订阅档位限制；大文件上传慢，进度不可见，只能看 `brctl status` 或日志；关闭“优化存储”后 iCloud 不会 evict，此时就靠我们自己的缓存目录来释放空间（所以自建本地缓存是必要的）。

### 2.3 macFUSE、FSKit、rclone
- **macFUSE 5**：新增 FSKit 后端（`-o backend=fskit`，需要 macOS 15.4+），不需要内核扩展；5.1 起 **macOS 26 上可以挂“非本地”卷**；默认仍是内核扩展后端，Apple Silicon 上要降低安全策略才能装。([5.0](https://macfuse.github.io/2025/05/05/macfuse-5.0.0.html), [5.1](https://macfuse.github.io/2025/10/30/macfuse-5.1.0.html))
- **Apple FSKit**：15.4 起提供，以 App Extension 形式实现用户态文件系统。([15.4 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-15_4-release-notes.md))
- 可以用来做“按块懒加载的 App 仓库”（效果接近 App-V 的流式加载），但工作量大、边界情况多。**MVP 不做。**
- `rclone mount --vfs-cache-mode full`（依赖 macFUSE 或 nfsmount）适合当传输或缓存层，但不建议在上面直接运行 App。

## 3. App 身份问题（决定哪些 App 能“无盘”）

- **代码签名和公证**：签名只和 bundle 内容绑定，**与路径和卷无关**。DMG 只读挂载不改动任何字节，签名始终有效。要避免对 App 做 ad-hoc 重签：重签会丢掉 entitlements（沙盒、App Group、钥匙串访问组），AppPorts 实测发现这类 App 在 macOS 27 上会因为身份不匹配而打不开。([AppPorts 文档](https://docs-appports.shimoko.com/datamigrae/container-identity.html))
- **App Translocation 和隔离属性**：只有同时满足三个条件才会触发：带 `com.apple.quarantine`、通过 LaunchServices 打开、没有被单独移动过。我们自己打的 DMG 不带 quarantine，挂载出来的 App 也不会带。打包时检查 App 和镜像，有 quarantine 的先清除（前提是这个 App 已经在本机通过过 Gatekeeper）。([eclecticlight](https://eclecticlight.co/2024/05/14/lost-in-translocation/), [Apple DTS](https://developer.apple.com/forums/thread/724969))
- **TCC**（屏幕录制、辅助功能、完全磁盘访问等）：授权按 bundle ID 加签名的 designated requirement 记录，路径通常无关，所以从 DMG 运行一般能沿用授权。少数旧 App 或未签名 App 是按路径记录的，换路径后要重新授权。**需要实测**。
- **只能放在 /Applications 才能用的 App**：带特权 helper（SMJobBless 或 SMAppService）、系统扩展、网络扩展、驱动、带 LaunchDaemon 的 App（例如 VPN、虚拟化软件、Docker、Adobe CC、Office 的部分组件）。这类 App 走“临时还原”模式，或者直接不支持。
- **自动更新（Sparkle、Electron 自带更新器）**：在只读卷上无法更新，这反而是好事，避免了改坏镜像。处理方式是在本工具里提供“刷新版本”：还原到本地 → 更新 → 重新打包上传。
- **Mac App Store 应用**：Apple 自己从 15.1 起允许把大于 1GB 的 MAS App 装到外接 APFS 磁盘，说明收据和 FairPlay 并不强绑定内置盘路径。但我们的 DMG 挂载不是“外接盘”，**需要实测**；MVP 默认把 MAS App 划到“临时还原”模式。([Apple](https://support.apple.com/guide/app-store/download-install-large-apps-a-separate-disk-fir06754f864/mac))
- **macOS 27 注意**：bundle 和签名校验更严格（Info.plist 必须有 `CFBundleExecutable`；dylib 加载要满足 Launch/Library Constraint）。我们生成的 Stub 要规范签名。([示例](https://github.com/LibreSprite/LibreSprite/pull/627))

**适用性分级**：
- ✅ **挂载模式**：自包含的 GUI App，例如 Blender、各类 IDE 的独立安装版、Affinity、游戏、Electron App（要关掉自动更新）、各种独立工具。
- ⚠️ **还原模式**：MAS App、带 helper 或登录项的 App、依赖插件目录或要求在 /Applications 的 App。
- ❌ **不支持**：系统扩展、驱动、VPN、Xcode（它会在系统里注册组件，太重）。

## 4. 符号链接和 bundle 重定向路线（明确不选）
- `ln -s` 到远端：Finder 图标有箭头；**Spotlight 和 Launchpad 不收录**，Alfred 也搜不到；LaunchServices 时好时坏；远端卷没挂上时链接直接失效。([SE](https://apple.stackexchange.com/questions/23653), [HN](https://news.ycombinator.com/item?id=43270592))
- 只链接 Contents（本地保留空的 .app 壳）：图标显示正常，但**自动更新器会顺着链接改写远端那份**，AppPorts 已因此弃用这个方案。
- **正确做法是 Stub Portal**：本地放一个真实的最小 .app，包含 launcher、图标和精简的 Info.plist，bundle ID 加后缀，再签名。这样不碰原 App 的签名，Spotlight、Launchpad、Dock 都正常。AppPorts 已经验证过这条路。([AppPorts 迁移策略](https://docs-appports.shimoko.com/migration-strategy/portal.html))
- Stub 的细节：复制原 App 的 `CFBundleDocumentTypes` 和 URL Schemes，这样“打开方式”和双击文档都能经 Stub 转发（`open -a <真实路径> --args/文件`）。代价是 LaunchServices 里会出现两个注册项，可以用 `-nobrowse` 挂载并在卸载后 `lsregister -u` 清理。你有开发者账号，Stub 用 Developer ID 签名，身份稳定，可选再做公证。

## 5. App 数据
- **默认数据留在本地**：`~/Library/Application Support`、`Preferences`、`Containers`、`Group Containers` 都不动。好处是体积通常不大、不会触发沙盒问题、多台 Mac 各自独立。
- **v2 可选数据归档**（参考 Storage Studio 和 AppVault）：打成第二个镜像，“冷藏”时连数据一起带走。沙盒容器不能用符号链接（沙盒会拒绝），要用整体拷贝，或者 AppPorts 那种“APFS 卷挂到原路径”的做法。**Caches 直接删除即可**。

## 6. 缓存、离线、一致性
- **状态机**：`remote → downloading → cached(verified) → mounted → running → idle → evictable`。
- **固定**：常用 App 标记 pin，永不淘汰。**预取**：按使用频率，或者出门前一键“离线包”。**淘汰**：LRU，同时保证可用空间不低于设定阈值。
- **完整性**：manifest 记录 sha256、cdhash 和 Team ID。下载后做哈希校验，挂载后执行 `codesign --verify --deep --strict` 和 `spctl -a`（首次跑一次即可）。UDIF 自带的校验可以用 `hdiutil verify`。
- **多台 Mac**：镜像不可变、按内容寻址，所以天然无冲突。manifest 每台设备写各自的 `devices/<host>.json`。数据目录不共享，避免两台机器同时写。

## 7. OpenList（第二阶段）
- 它是 AList 的社区分叉，支持 40 多种存储：本地、SMB、FTP/SFTP、S3、WebDAV、OneDrive、Google Drive、Dropbox、阿里云盘、百度网盘、115、夸克、123、天翼、PikPak、Mega、Proton 等。([GitHub](https://github.com/OpenListTeam/OpenList))
- 对外提供 `/dav` 的 WebDAV 服务（读写权限分开授予），GET 请求可以配置成 302 跳转到网盘直链，也可以由服务端代理。([DeepWiki](https://deepwiki.com/openlistteam/openlist/4.2-webdav-protocol), [AList 文档](https://alist-repo.github.io/docs/guide/webdav.html))
- REST API（沿用 AList）：`/api/auth/login`、`/api/fs/list`、`/api/fs/get`（会返回 raw_url）、`/api/fs/put`。
- **限速**：取决于背后的网盘。百度、阿里等对非会员限速，会风控，直链也会过期。OpenList 自身不额外限速。可以部署在你的 Oracle VM 上，必要时用它做中转代理。
- **大文件结论**：**不要在 WebDAV 挂载上直接挂 DMG**（macOS 自带的 webdavfs 慢而且不稳定）。应该用 HTTP Range 多线程把整个镜像拉到本地缓存，再挂载。存储后端抽象只需要实现 `list / stat / get(range) / put / delete` 五个操作。

## 8. 同类项目（社区与开源）

| 名称 | 链接 | 热度/活跃 | 做什么 | 可借鉴 |
|---|---|---|---|---|
| **AppPorts** | [github.com/wzh4869/AppPorts](https://github.com/wzh4869/AppPorts) | ★2.1k，Apache-2.0，2026-10 仍在提交 | 把 App 迁移到外置盘或 NAS，本地留 Stub Portal；数据目录迁移；容器用 APFS 卷挂载 | **最接近**：Stub 生成、自更新保护、沙盒容器的坑、macOS 27 重签问题。不支持云端按需拉取 |
| App Playpen（犹他大学） | [GitHub](https://github.com/univ-of-utah-marriott-library-apple/app-playpen) | ★11，2021 后停更 | 为 App 生成“挂只读 DMG + shadow 再启动”的 launcher，支持启动前后执行脚本 | **DMG 启动器模式的先例**，正好对应方案 A |
| Storage Studio | [storagestudio.us](https://storagestudio.us/wiki/offloading-an-app) | 商业，2026-10 有更新 | 把 App 移到外置盘、或连同数据离线归档，再一键还原 | 冷藏和还原的交互、数据清单 |
| AppVault | [bundlehunt](https://bundlehunt.com/appvault) | 商业 | 归档 App 和设置、授权，本地留占位 | 数据和授权的完整归档 |
| EasyDMG | [GitHub](https://github.com/jeff-schumann/EasyDMG) | 开源，活跃度未核实 | 自动完成 DMG 挂载、安装、启动、清理 | hdiutil 和 Gatekeeper 检查流程 |
| Offloader / CloudRm | [r/macapps](https://www.reddit.com/r/macapps/comments/1meupo9/), [CloudRm](https://github.com/olchu/CloudRm) | 小型 | 主动 evict iCloud 文件来释放空间 | evict API 的实际用法 |
| Apple 官方 | MAS“大型 App 装到外接盘”(15.1+)；iOS“卸载未使用的 App” | — | 前者把 App 放外接盘；后者删掉 App 本体、保留数据和图标 | **“保留数据和图标、本体按需拉回”正是 iOS Offload 的模型** |
| Windows App-V / MSIX App Attach | Microsoft 文档 | 成熟 | 把 App 打进 VHD(X)/CIM 镜像，登录或启动时按需挂载 | 和方案 A 几乎同构，证明“镜像挂载式分发”可行 |
| Linux AppImage | appimage.org | 成熟 | squashfs 单文件 + FUSE 挂载运行 | 单文件、自包含、只读 |
| Steam | — | 成熟 | 安装库可以放在任意盘，按需安装和卸载，有校验 | 清单、校验和多库管理 |

**结论**：**没有找到在 macOS 上做“云端或 NAS 存储 + 按需挂载启动”的成熟开源项目**。最接近的是 AppPorts（本地外置盘）和 App Playpen（DMG 启动器，已停更）。本项目的差异点是“远端仓库 + 本地 LRU 缓存 + DMG 挂载”。V2EX 和 linux.do 上的讨论大多停在软链接或把整个系统装到外置盘（linux.do 的搜索接口返回 403，没有检索到）。

## 9. 推荐 MVP 架构（iCloud 优先）

```
/Applications/Foo.app (Stub, Developer ID 签名)
      │ 点击
      ▼
wupand (LaunchAgent, Swift)  ←→  wupan CLI / 菜单栏 App
  ├─ Catalog: manifest.json (bundleId, ver, sha256, cdhash, teamId, mode, size)
  ├─ Backend 抽象: list/stat/get(range)/put/delete
  │    ├─ iCloudBackend (MVP)：~/Library/Mobile Documents/.../Wupan/ + startDownloading/evict
  │    ├─ LocalPathBackend（SMB/NFS 已挂载路径）    ← Phase 2
  │    └─ HTTP/WebDAV/OpenList API Backend           ← Phase 2
  ├─ Cache: ~/Library/Caches/Wupan (LRU, pin, 配额, sha 校验)
  └─ Runner: attach -readonly -nobrowse → open → 监听退出 → 延迟 detach
```

**打包流程**：`wupan pack /Applications/Foo.app`
1. 检查签名、quarantine、helper 和 MAS 收据，自动判定用挂载模式还是还原模式。
2. 用 `hdiutil create ULMO` 打包。
3. 计算 sha256，写入 manifest。
4. 拷进 iCloud Drive 的 Wupan 目录。
5. 等上传完成（`brctl` 或 `NSMetadataQuery`）。
6. 生成并签名 Stub。
7. 删除原 App（先移到废纸篓，可回滚）。
8. 原件 evict。

**启动流程**：
1. 命中本地缓存就直接挂载。
2. 没命中：iCloud 下载（Stub 弹出进度窗口）→ 校验 → 挂载 → `open` 真实 App，同时转发文档参数。
3. App 退出后 N 分钟卸载，更新 LRU。

**路线图**：
- **MVP（2–3 周）**：CLI 加 LaunchAgent，只做 iCloud 后端；挂载模式和还原模式；Stub 生成；LRU 和 pin；先在 10 个常用的冷门 App 上实测兼容性。
- **v1**：菜单栏 App（进度、空间、pin）；“刷新版本”流程；兼容性数据库。
- **v2（Phase 2）**：NAS 后端（SMB/NFS 路径或 HTTP）；OpenList 后端（部署在 Oracle VM，Range 多线程拉取）；可选的 App 数据归档；多台 Mac 共享目录。
- **v3**：FSKit 懒加载（按块按需读，冷启动不必整包下载）；镜像分块去重，版本更新只传差异。

## 10. 关键风险
1. iCloud 大文件上传和下载慢、进度不透明；用量还会挤占 iCloud 配额。
2. 部分 App 首次运行在新路径会重新请求 TCC 授权，或者丢失授权许可，要逐个实测。
3. 自动更新：被冷藏的 App 版本会逐渐过时，安全更新需要人工“刷新”。
4. macOS 27 签名约束更严格，Stub 的生成和签名要跟着系统版本调整。
5. 同一个 bundle ID 有多份注册（Stub 和真实 App），可能让“打开方式”和默认 App 关联混乱。

## 11. 需要你确认的问题
1. “Strata”是不是指 Niko1221/Strata 那种“SSD 按需加载”的思路？还是别的产品？
2. 当前系统版本是 15、26 还是 27？iCloud 是否开了“优化 Mac 储存空间”？iCloud 剩余容量有多少？
3. 准备冷藏的 App 清单和大致体积？里面有没有 MAS App 或带 helper 的 App？
4. App 数据要不要一起冷藏（MVP 默认不冷藏）？
5. 是否需要多台 Mac 共享同一个仓库？
6. Stub 是否需要公证？自用的话签名就够了。
