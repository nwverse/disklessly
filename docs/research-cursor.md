# Mac 无盘：补充调研（2026-10-20）

对照 [docs/research.md](research.md) 里标成「需实测」或写得偏薄的部分。只读源码和公开资料，**没有在 macOS 15 / 26 / 27 上跑过**。下面凡是写「仍需实测」的，都是文献缺口，不是已经证伪。

源码快照：AppPorts `main`，2026-10-20 仍在提交（★2139，Apache-2.0）；App Playpen 最后提交 2021-02-04（★11，MIT）。

---

## 1. AppPorts 与 App Playpen

两者解决的不是同一件事。AppPorts 把真 app 放在**已经挂好的外置卷**上，本地只留启动壳，启动后立刻退出，**不挂 DMG、不等进程结束**。App Playpen 把 app 打进只读 DMG，启动壳负责 attach、shadow、轮询退出、detach。无盘要的是 Playpen 的生命周期加上 AppPorts 的入口元数据，两边都不能整段搬过来用。

### 1.1 AppPorts：Stub 怎么生成

入口在 `AppPorts/Services/AppMigrationService.swift` 的 `createStubPortal`（约 1812 行）。macOS app 走 `createMacOSStubPortal`（1895 行），先写到同目录的隐藏临时包 `.appports-create-<uuid>.app`，签完名再用 `renameatx_np(..., RENAME_EXCL)` 换到目标路径。

目录：

- `Contents/MacOS/launcher`：预编译 Mach-O，源码是 `Tools/StubLauncher/StubLauncherSource.swift`，随包资源名 `StubLauncherBinary`。找不到二进制就退回 bash（`writeBashLauncher`，2203 行）。
- `Contents/Resources/real_app_path.txt`：一行，外置 `.app` 的绝对路径。
- `Contents/PkgInfo`：外置包里若是普通文件就拷过来；符号链接且解析后不在该 app 内则拒绝。
- `Contents/Info.plist`：由 `AppPorts/Utils/PortalPresentation.swift` 的 `write(from:to:)` 生成。

**Info.plist 不是手写几项，而是整份拷贝后再改：**

| 动作 | 位置 |
|---|---|
| 保留 `CFBundleDocumentTypes`，并尽量拷对应的 `CFBundleTypeIconFile` | `PortalPresentation.swift` 106–115 行 |
| **不删除** `CFBundleURLTypes`，所以 URL scheme 会留在壳上 | 同文件，只删 Sparkle/Electron 键（150 行） |
| `CFBundleExecutable` = `launcher` | 147 行 |
| `CFBundleIdentifier` 追加 `.appports.stub` | 149 行 |
| 原文 bundle id 另存为 `AppPortsTargetBundleIdentifier` | 143 行 |
| 外置卷 UUID 写入 `AppPortsTargetVolumeUUID` | 144–146 行 |
| `LSUIElement` = true | 148 行 |
| 去掉 `SUFeedURL`、`SUPublicEDKey`、`ElectronDefaultApp` 等更新器键 | 150 行 |
| 图标：传统 `.icns`，以及 `CFBundleIconName` / `Assets.car` / `.icon`；拷不到就删掉对应键 | 78–105 行 |
| `.lproj` 里只留 `CFBundleName` / `CFBundleDisplayName` / `CFBundleSpokenName` | 117–142 行 |

本地化字符串只滤显示名，是为了避免把外置包的 `CFBundleExecutable` 或权限描述写进壳。

**签名**（`signAndVerifyPortal`，2112 行）：先 `xattr -crs`，再 `codesign --force --sign -`（ad-hoc），再 `codesign --verify --strict`。没有 `--deep`。要求包内普通文件硬链接数为 1，避免签到外置真 app 上。iOS 包装（`Wrapper/` 或 `WrappedBundle/`）用 bash 启动器，注释写明 shell 脚本无法 codesign（1882 行）。

**启动转发**（`StubLauncherSource.swift`）：

- `applicationDidFinishLaunching`：外置路径存在则 `open <真.app>`，然后 `NSApp.terminate`。**不转发命令行参数。**
- `application(_:openFiles:)`：对每个文件 `open -a <真.app> <file>`，回 `success` 后退出。这是 1.6.2 引入原生启动器的原因（`User_docs/docs/archive/app-strategies.md`「启动壳的实现变化」）。
- **没有** `application(_:open urls:)`。壳的 plist 里可以有 URL scheme，但这个启动器会把 URL 丢掉，只把真 app 空打开。
- bash 降级只 `open "$REAL_APP"`，文档参数也丢。
- 外置盘不在时用 `osascript` 弹一句「外部存储未连接」。`setActivationPolicy(.prohibited)`，进程不当普通前台 app。

**退出检测：没有。** 壳把 `open` 拉起来就退出。真 app 继续跑，卷一直挂着。这和「退出后 detach」不是同一条路径。

**Launch Services：** 创建和刷新后 `lsregister -f <壳>`（2151 行），不是 `lsregister -u`。外置真 app 用原 bundle id，壳用另一个 id。Dock 磁贴若还指着 `.appports.stub`，`DockShortcutService.swift` 会改回真 app（约 234、287 行）。外置 app 版本变了会 `refreshStubPortal`，否则「打开方式」一直显示旧版本（changelog #50）。

### 1.2 AppPorts 踩过的坑（值得直接避开）

- **不要重签真 app。** ad-hoc 会丢掉沙盒、App Group、钥匙串访问组。他们在 macOS 27.0（构建号 26A428 / 26A434，这是 2026 的系统，不是 Tahoe 26）上看到重签后的微信打不开。见 `User_docs/docs/principles/macos-27.md`、`User_docs/docs/archive/data-signing.md`。1.9.x 起登录自动重签已停用。
- **Contents 符号链接已弃用。** 更新器会顺着链接改外置真包。1.2.0 起默认改 Stub。整体符号链接仍可手动选，Finder 会画出箭头。见 `User_docs/docs/archive/app-strategies.md`。
- **壳不能冒充原 bundle id。** 他们明确写：不要为了藏 Dock 重复图标而让壳冒充外置 app（`CLAUDE.md` 约 330 行）。
- **更新保护是 `chflags uchg`，只对检测到 Sparkle/Electron 的包。** 能挡住一部分自更新，也会把更新卡死；1.9.0 还有「锁了但没记账」的遗留，后来专门做了收养逻辑（`AppTransferStore.swift`）。只读 DMG 本身就能挡住写入，不必再套 uchg。
- **MAS 不能当普通文件删。** 迁移商店 app 要借 Finder Apple Event，用户得给「自动化」权限（`User_docs/docs/zh-Hant/privacy.md`）。macOS 15.1+ 的外置安装是系统功能，不是把 `.app` 拷到任意卷。
- **透明混合入口是默认关闭的原型**（`createTransparentHybridPortal`）。`_CodeSignature` 一旦是指向外置包的符号链接，重签会写穿真 app。不要学这个。
- 数据容器用符号链接会被沙盒拒绝；他们改成把 APFS 卷挂到原路径，并保留官方签名。这是数据迁移，不是 app 本体。微信挂载恢复的笔记都在 `.agents/notes/implemented/bug-fix/`，和「只读 DMG 跑 GUI」不是同一类故障。

### 1.3 App Playpen：DMG 启动器

构建逻辑在 `Crappy_App_Logic.py`，界面采集在 `App_Playpen.py`。模板是 `Reserve/Original-Template.app.zip`，运行脚本是 `Contents/Resources/Original-Template.py`（2021-02-02）。

**生成：**

1. `/tmp` 里 `hdiutil create -size <N>g -fs HFS+J -type SPARSE`，attach，在卷里建 `Applications/`，`copytree` 真 app。
2. 用户手动打开一次做初始化，再 detach。
3. `hdiutil convert -format UDRO`，再 `hdiutil segment -segmentSize 1g`。分段 UDIF 在 macOS 12 已弃用。
4. 分段 DMG 塞进 py2app 模板的 `Contents/Resources/`。
5. `changePlist` **只改四项**：`CFBundleIconFile=icon`、`CFBundleName`、`CFBundleShortVersionString`、`CFBundleIdentifier`（**与真 app 相同**）。不拷文档类型，不拷 URL scheme，不签名。模板 plist 里 `LSUIElement` 是字符串 `"1"`，不是布尔。

**启动**（`Original-Template.py` 的 `launchApplication`）：

```text
hdiutil attach -nobrowse -noautoopenro -noverify -mountroot /Volumes -shadow <shadow> <dmg>
```

shadow 在 `~/Library/Application Support/<卷名>/<卷名>.shadow`。然后 `open` 卷里第一个 `.app`。pre / post / close 脚本用 `runpy` 跑，空目录也会被 listdir。

**退出检测：** `psutil.process_iter()`，进程名（去空格、转小写）**包含 DMG 文件名主干**即视为在跑，每 5 秒 poll 一次。判定的是名字子串，不是可执行文件路径。

退出后的顺序是：`rm -rf` 整个 shadow 目录 → close 脚本 → `hdiutil detach`，失败就再睡 5 秒。**没有 `-force`。** shadow 在卷还挂着时就被删。

**已知缺陷（源码里就能看见）：**

- 启动后先 `sleep 5` 再进入 while。5 秒时进程还没出现，就会直接拆卷。
- 名字子串会误判（别的进程带了 app 名就永远不 detach），也会漏判（helper 不叫这个名字，主进程一退就 detach）。
- 同一 bundle id 的壳和真 app 会抢 Launch Services / TCC。
- 嵌入的是 Python 3.8 + py2app 0.22，未签名。2021 年后无提交。
- `processHelper` 见到 `Resource temporarily unavailable` 会递归重试，没有上限。

### 1.4 什么能复用

| 来源 | 许可证 | 建议 |
|---|---|---|
| AppPorts | Apache-2.0 | 思路可复用：独立 bundle id 后缀、`LSUIElement`、整份 plist 再删更新器键、文档类型图标单独拷、ad-hoc 只签壳、`lsregister -f` 只登记壳、外置路径用资源文件而不是写死在二进制里。若拷 `PortalPresentation.swift` 或 `StubLauncherSource.swift`，必须带 Apache 声明和修改说明。启动器只有一百多行，重写比携带他们的文案和资源布局干净。 |
| App Playpen | MIT，Copyright 2020 University of Utah, Marriott Library | 可以抄，但值得留的只有三件事：只读镜像 + 每用户 shadow、启动前/后/退出三支脚本、退出后再 detach。实现本身不要移植。 |

壳用 Developer ID 签，真 app 一个字节不动。AppPorts 的 ad-hoc 只够本机调试：ad-hoc 的 designated requirement 绑 cdhash，壳一旦重做，给壳的 TCC 就失效。壳如果只调用 `open`，它自己通常不需要 TCC。

---

## 2. iCloud Drive（macOS 15 / 26）

### 2.1 对 dataless DMG 直接 attach

没有找到「`hdiutil attach` 一个已 evict 的 DMG」的成功记录。相邻证据是否定的：

- dataless 文件只有元数据，读时才物化（[TN3150](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-dataless-files)）。
- 不经文件协调的 `mmap` 会在 dataless 文件上失败。`icloud-tools` 把 `rsync` 的 `mmap: Resource deadlock avoided` 当作必须先下载的理由（[README](https://github.com/icanhasjonas/icloud-tools)）。`diskimages-helper` 用 mmap / pread，不走 `NSFileCoordinator`。
- File Provider 物化是整文件换 extent，不是给压缩 DMG 做随机读流（同一 README：`fileAllocatedSize` 从 0 一次跳到完整大小）。

结论：attach 之前必须确认已经物化。判据用 `fileAllocatedSize == 0 && fileSize > 0`，或 `ubiquitousItemDownloadingStatus == .current` 且分配大小接近逻辑大小。只调用 `startDownloadingUbiquitousItem` 就立刻 `hdiutil` 不够，那个 API 是异步的，返回时下载还没开始。

### 2.2 非沙盒 CLI 调用 download / evict

公开、可编译的反例已经把 `docs/research.md` 里的 `brctl download` / `brctl evict` 否定了：

- macOS 14.4 起 `fileproviderctl materialize` 和 `evict` 从帮助里消失（[Iva Horn](https://i2h3.de/fileproviderctl-changes-macos-14.4/)）。
- `brctl download` / `brctl evict` 在 Sonoma 14+ 被拿掉，没有官方替代 CLI（[icloud-tools](https://github.com/icanhasjonas/icloud-tools)，MIT，要求 macOS 14+、Swift 6）。该工具无沙盒、无 entitlement、可以不签名，直接对 `~/Library/Mobile Documents/` 调 `FileManager.startDownloadingUbiquitousItem(at:)` 和 `evictUbiquitousItem(at:)`。
- Apple 文档仍列出这两个方法（[startDownloadingUbiquitousItem](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem(at:))、[FileManager iCloud 项](https://developer.apple.com/documentation/foundation/filemanager)）。

这是「14+ 上有人做成了未签名 CLI」，不是「15 和 26 的矩阵已经测完」。固定路径是 `com~apple~CloudDocs`。Desktop 与 Documents 只有在用户打开了 iCloud 桌面与文稿同步时才算。`evict` 在「优化 Mac 储存空间」关闭（复制模式）时没有意义，文件本来就不能变成 dataless。

进度：不要指望字节百分比。旧的 `NSMetadataUbiquitousItemPercentDownloadedKey` 在 File Provider 时代经常不连贯；`icloud-tools` 只报告排队 / 下载中 / 完成。大 DMG 的 UI 只能做不确定进度，或者拿已分配大小自己估，而且那个值可能长时间为 0 然后跳满。

### 2.3 `cp -c` 之后 evict 原件

[Howard Oakley，2025-04-07](https://eclecticlight.co/2025/04/07/how-robust-are-apfs-clone-and-sparse-files/) 测的是 **iCloud Drive 域里面的克隆对**，不是「克隆到 `~/Library/Caches` 再 evict 原件」：

- 域内两个克隆在本地可以共享 extent，但 iCloud 配额按两份满尺寸计。
- evict 会去掉本地数据。重新下载后不再恢复共享 extent，克隆关系消失。他写明这个过程很难直接观察。
- 结论原文：克隆只在**没有被 evict** 时才在 iCloud Drive 里保持。

因此 `docs/research.md` 的「clone 再 evict，零拷贝缓存」**没有被这篇实测支持**。域外克隆（同一 APFS Data 卷、目标不在 File Provider 域）理论上应靠 COW 留下 extent，但没有公开实验。另外：

- 源文件仍是 dataless 时，`cp -c` 克隆的是占位，不是数据。
- 跨卷 `clonefile` 会退化为真拷贝。iCloud Drive 和 `~/Library/Caches` 通常同在 Data 卷，这点成立，但不能当成 evict 安全。

在本机实验做出「evict 之后缓存文件的 `fileAllocatedSize` 仍等于原大小，且能 `hdiutil verify`」之前，缓存用 `ditto` / `cp` 真拷贝。空间按两份估算。

### 2.4 「保持下载」没有公开 API

Sequoia 起 Finder 的 Keep Downloaded 就是扩展属性，不是 `FileManager` 方法（[Oakley，2024-09-16](https://eclecticlight.co/2024/09/16/sequoia-introduces-pinning-to-icloud-drive/)）：

- 名字是 `com.apple.fileprovider.pinned`，内容一个字节 `0x31`。他后来写过把内容改成 `0` 也同样算钉住，关键是属性在不在。
- `icloud-tools` 写成 `com.apple.fileprovider.pinned#PX`。`#PX` 是 `xattr` 带标志时的显示形式，不是另一个属性。
- 只在「优化储存空间」打开时有用。钉住的文件会抵抗系统自动 evict；`icloud-tools` 的 evict 会跳过它们。
- 钉住状态是**这一台 Mac** 的。Oakley 写过它不强迫同一 iCloud 账号的其他 Mac 保持下载。后来的日志里能看到 `FPPinOperation` 记进云端 FSTree（[2024-09-30](https://eclecticlight.co/2024/09/30/how-icloud-has-changed-in-sequoia-pinning-and-more/)），那是元数据同步，不能当成跨机器的 pin 策略。
- 拷贝不继承这个 xattr。移动（同卷）会带走。

没有更官方的「pin API」。自己 `setxattr` 是在模仿 Finder，系统随时可能改属性名。对「这台机器的仓库副本不要被系统 evict」够用；多台 Mac 的固定策略放在我们自己的 manifest 里。

### 2.5 上传完成

不要用 `brctl status` 当完成条件。文件级键是：

- `URLResourceKey.ubiquitousItemIsUploadedKey`：当前版本已经到云端（[旧文档表](https://developer.apple.com/library/archive/documentation/CoreServices/Reference/MetadataAttributesRef/Articles/iCloudAttrs.html)，键今天仍在 `URLResourceValues` 上）。
- `ubiquitousItemIsUploadingKey == false`，且 `ubiquitousItemUploadingErrorKey == nil`。只看 `isUploaded` 会把「上一版已上传、这一版还在传」当成完成。
- 百分比用 `NSMetadataQuery` 的 `NSMetadataUbiquitousItemPercentUploadedKey`。大文件上它一样可能很粗。

拷进 `Mobile Documents` 之后这些键是异步变的。安全条件是连续两次观察到「不在上传且已上传」，再 evict 或删本地原 app。`icloud-tools` 的经验是：成功与否用操作后的 `fileExists` 和大小核对，不相信调用返回值本身。

`docs/research.md` 的单文件 50GB 上限这次没有重新打开 Apple 支持页核对，不把它写成新结论。

---

## 3. hdiutil

macOS 27（Golden Gate）的 man 页已经写明 `hdiutil` **弃用**，对应接口是 `diskutil image`（attach / create / resize / info / chpass；detach 对应 `diskutil eject`）。ASIF 只存在于 `diskutil image`，`hdiutil` 不认识。弃用不等于 27 里已经删掉；[AppleInsider 2026-08-24](https://appleinsider.com/articles/26/08/24/handy-disk-image-tool-is-to-be-removed-from-macos) 引 Jeff Johnson：27 仍可用，以后的系统会拿掉。`diskutil image` 和 `hdiutil` 行为不完全相同（例如 root 拥有的文件，一边弹认证、一边直接失败）。

[DiskImageKit](https://developer.apple.com/videos/play/wwdc2026/224/) 是 macOS 27 的虚拟化框架：ASIF / RAW、只读基线加 cache/overlay。cache 层是为「基线在慢存储上」设计的，但是 **VM 块设备**，不是「把 .app 目录挂成只读卷给 Launch Services」。不能拿它替换 MVP 的 DMG。

### 3.1 格式和已发表的速度

man 页：ULFO（LZFSE，10.11+）**内核支持**；ULMO（LZMA，10.15+）更小，**不在内核**，必须走 `diskimages-helper`，更早的系统打不开。随机读 ULMO 会更差，因为压缩块不能在内核里按需解。

一份公开测量（327MB 的 Slack.app，三次取中位数，[picklog](https://picklog.cc/blog/hdiutil)）：

| 格式 | 大小 | 创建 | ditto 拷出 |
|---|---|---|---|
| UDRO | 327.6 MB | 5.8 s | 0.65 s |
| UDZO | 144.5 MB | 8.1 s | 0.69 s |
| ULFO | 129.8 MB | 6.9 s | 0.51 s |
| ULMO | 99.3 MB | 42.6 s | 2.81 s |

这是热缓存下的顺序读出，不是挂载后跑 app 的随机读。electron-builder 的经验是 ULMO 比 UDZO 大约小 30%，挂载和拷贝多几秒（[文档](https://www.electron.build/docs/dmg)）。另一个 Java 目录上 ULMO 只比 ULFO 小一点，但创建慢五倍（[cumt.org](https://cumt.org/blog/861)）。压缩率取决于二进制密度，**不要把「原大小的 50–70%」写成 ULMO 的保证**。

ASIF 的数字是另一类东西。Oakley 在 M3 Pro 内置 SSD、macOS 26 beta 上，100GB ASIF 里顺序读写约 5.8 / 6.6 GB/s（加密后 4.8 / 4.6）；空镜像仍占 1–3GB（[2025-06-12](https://eclecticlight.co/2025/06/12/macos-tahoe-brings-a-new-disk-image-format/)）。它是稀疏读写容器，适合 VM，不适合当压缩仓库。15.5 能挂载别人做好的 ASIF，但不能创建。

建议分工：远端仓库用 ULMO（小、上传少）；本地缓存若要启动快，转成 ULFO 或 UDRO。转换成本在第一次缓存时付。`-shadow` 每台机器单独一份，和 Playpen 一样；只读 app 不需要 shadow，除非确认它会写自己的 bundle。

### 3.2 busy、`-force`、活过主进程的 helper

`hdiutil detach` 在有打开文件时返回非 0，常见文本是 `couldn't unmount "diskN" - Resource busy`（exit 16 这一档）。持有者通常是：当前工作目录在卷里的 shell、`mds` / `mds_stores`、`fseventsd`、app 的 GPU / crashpad / 渲染进程。

`-force` 的 man 页原文是 ignore open files。效果是 Disk Arbitration 强制卸载：已映射的只读页会 `SIGBUS`，普通读写返回 `EIO`，进程崩溃或卡住。只读镜像的**源文件**不会因此损坏；shadow 会被打断，可能留下脏 shadow。强制卸载做到一半时，`diskimages-helper` 和 `/dev/diskN` 可能还在，下一次 attach 继续 busy。

Electron、Chrome、很多带登录项的 app，主进程退出后 helper 仍把卷上的二进制映射着。`NSWorkspace` 的 `didTerminateApplication` 只覆盖 Launch Services 启动的那个主 app。Playpen 那种「进程名包含 app 名」会在 helper 还活着时拆卷，也会被无关进程拖住。

可用的判定是：挂载点之下没有 `proc_pidpath` 落在该前缀的进程，并且 `lsof` 对该挂载点为空。然后再 detach；失败就退避重试。`-force` 只作为超时后的最后一步，接着 `hdiutil info` 确认设备没了。

### 3.3 Spotlight、`-nobrowse`、Gatekeeper

`-nobrowse` 设置 `MNT_DONTBROWSE`。Finder 不显示，Spotlight 也不索引：`mdutil` 对这种挂载会报 Indexing and searching disabled（[Ask Different](https://apple.stackexchange.com/questions/126862/spotlight-not-indexing-secondary-drive)）。这正是想要的，不必再为了「避免索引」去 `mdutil -i off`，但 `mds` 仍可能在挂载瞬间碰一下卷，所以 detach 要能重试。

Quinn 在开发者论坛写过：`hdiutil attach` **不会**做 Gatekeeper 评估；`open` / `NSWorkspace` 打开 dmg 或 app 才会，公证票也是在那次评估里被吃进去（[thread 741219](https://developer.apple.com/forums/thread/741219)）。XProtect 扫的是执行，不是 attach。第一次 `open` 真 app 时扫描会拖住几秒，并在扫描期间让 detach 变 busy。

man 页还说，磁盘映像这种「不受信任的设备」默认带 `nosuid` 和 quarantine **挂载选项**。这不等于文件上有 `com.apple.quarantine` 扩展属性。App Translocation 要的是扩展属性 + 经 Launch Services 打开 + 用户没把 app 单独移出映像（[Oakley](https://eclecticlight.co/2024/05/14/lost-in-translocation/)、[DTS](https://developer.apple.com/forums/thread/724969)）。我们自己创建、经 iCloud 同步的 DMG 通常不会被浏览器打上 quarantine；若 `xattr` 看得到，在我们自己校验通过之后删掉再 attach。镜像里面的 app 如果打包时带了 quarantine，挂载选项不会替我们清掉。

### 3.4 Launch Services 重复登记

`-nobrowse` 减少 Finder 扫描，不保证卷上的 `.app` 永不进 LS 数据库。一旦真 app 被 `open`，它会以**原 bundle id** 登记在挂载点路径上。壳是另一个 bundle id，所以不会覆盖真 app 的 TCC 记录，但「打开方式」会同时出现壳和真 app。

`lsregister -u <真.app路径>` 必须在 **detach 之前** 调用，因为注销按现存路径走。卷拆掉之后再 `-u`，悬空记录会留到下一次全局 `lsregister -gc`（慢，而且是系统级）。AppPorts 用 `-f` 只是为了刷新壳，他们的真 app 一直在线，所以没有这个问题。

---

## 4. TCC 与 Mac App Store

TCC 的客户身份是 bundle id（或非 bundle 二进制的路径）加上代码要求。Designated requirement 由签名决定：证书签名一般是 `identifier` + 证书链；ad-hoc 是 cdhash（[TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)）。MDM 的 PPPC 同样要求 bundle 用 bundle id，并附上 `codesign -dr -` 的那串要求（[配置描述](https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.TCC.configuration-profile-policy.yaml)）。

因此：**同一 Team ID、同一 bundle id、DR 没变**，从 `/Applications` 换到只读映像路径，授权记录按文档仍然指向同一个客户。路径本身不是主键。这和 `docs/research.md` 的判断一致，补充三点边界：

- 系统设置里辅助功能、输入监视、完全磁盘访问的开关列表经常按路径显示。运行时检查的是 DR。会出现「开关看着是开的，但 `AXIsProcessTrusted` 失败」，或者换路径后开关消失、需要用户再拨一次。麦克风比较会自己重新弹窗。
- 请求算在 **responsible 进程** 上。从壳 `open` 出去的是真 app，TCC 应记在真 app 上，而不是壳上。不要让壳和真 app 共用 bundle id（Playpen 就是这样，会把两边的授权搅在一起）。
- 重签真 app 会换 DR，旧授权全部作废。这是 AppPorts 在 macOS 27 上的实测方向，比「路径变了」严重。

**仍需实测的是窄问题：** 只读、`-nobrowse`、带 quarantine 挂载选项的映像上，第一次启动时 TCC 是否把客户记成被 translocation 的临时路径。没有 quarantine 扩展属性时，按现有规则不应该 translocation。

MAS：15.1 起「把大于 1GB 的 App 装到另一块盘」要求那块盘是 **App Store 设置里选中的外置 APFS**，而且是全部大 app 一起，不是逐个选择（[Apple](https://support.apple.com/guide/app-store/download-install-large-apps-a-separate-disk-fir06754f864/mac)）。盘不在线时系统提示重新下载。装好的 app 会出现在「应用程序」里，但是 Computerworld 记录过它们不进 Launchpad。这是 `storeagent` 管理的安装位置，不是任意 DMG。

自己 attach 的只读映像没有这条注册。收据在 `Contents/_MASReceipt/receipt`，校验失败时 app 会 `exit(173)`，商店按它知道的安装路径去修。只读卷上修不了，也没有人告诉商店「这就是安装位置」。沙盒容器仍按 bundle id 留在本机，一般还能用；更新、重新下载、部分「必须在 /Applications」的检查不会。MVP 把 MAS 放进还原模式，这个判断应保留，而且要比「挂载模式再试一次」更硬：还原才是和商店注册路径一致的做法。

---

## 5. Pake 做菜单栏

Pake（[tw93/Pake](https://github.com/tw93/Pake)，GPL-3.0，2026-10 仍在更新）能把一个 URL 包成 Tauri/wry 窗口。和菜单栏相关的 CLI（[选项](https://pake.run/docs/cli/options)）：

- `--show-system-tray`、`--system-tray-icon`（png/ico，32–256）、`--start-to-tray`（必须和 tray 一起用）。
- macOS 上 `--hide-on-close` 默认就是 true，点关闭是藏窗口不是退出。
- 没有「不要 Dock 图标」的开关。`LSUIElement` 不是 CLI 选项。tray 打开之后 app 仍会进 Dock 和 Cmd-Tab，除非事后改生成的 `Info.plist`，或改它写出的 `tauri.macos.conf.json`（Tauri 的 `bundle.macOS.dockIcon: false` 才会写 `LSUIElement`）。改完要重新签名。
- 没有菜单栏弹出面板（点图标在图标下方弹出无边框窗口）。那是 `tauri-plugin-positioner` 一类的东西，Pake 没暴露。

**和本地 daemon 通信：** 可行的方式是页面本身访问 `http://127.0.0.1` 或 `ws://127.0.0.1`。Pake 就是一个浏览器壳，`--inject` 只能在打包时塞 CSS/JS。自定义 Tauri `invoke` 必须改 `generate_handler!`、`src-tauri/build.rs` 和 capabilities（[advanced-usage](https://github.com/tw93/Pake/blob/main/docs/advanced-usage.md)），那就是 fork，不再是 `pake <url>`。IPC 只对打包时写死的那个 origin 开放，登录跳转走了就没了。

其他限制：WKWebView 里 Google 登录经常被拒；`--ignore-certificate-errors` 能对付自签本地证书，但 127.0.0.1 用明文 HTTP 即可，不必上 TLS。`--debug` 开 DevTools。macOS 的 `--proxy-url` 要 14+。

**签名和公证：** 3.9.1（2026-02-21）起他们的发布流程会签并公证。本仓库构建要看 CI：`.github/workflows/single-app.yaml` 读 `PAKE_SIGNING_IDENTITY`、`PAKE_CERTIFICATE_P12`、`PAKE_CERTIFICATE_PASSWORD`、`PAKE_NOTARIZE_APPLE_ID`、`PAKE_NOTARIZE_TEAM_ID`、`PAKE_NOTARIZE_PASSWORD`，写进 `src-tauri/tauri.macos.conf.json` 的 `bundle.macOS.signingIdentity`。没有证书就退回 ad-hoc `"-"`，过不了公证。公证本身仍是 Apple 的 Developer ID + Hardened Runtime + 时间戳（[文档](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)）。Tauri 侧的环境变量是 `APPLE_API_KEY` / `APPLE_API_ISSUER` / `APPLE_API_KEY_PATH`，或 Apple ID 加专用密码（[Tauri](https://v2.tauri.app/distribute/sign/macos/)）。

GPL-3.0 的边界：Pake 生成的壳是 GPL 程序。本地页面如果只是这个壳加载的 `localhost` 文档，通常按「浏览器加载网页」理解，daemon 不必因此变成 GPL。把前端资源打进壳、或 fork Pake 加 IPC，就和 GPL 程序链在一起。正式分发前要单独做许可决定。自用、不发壳的二进制，这个问题小。

若目标是真正的菜单栏（无 Dock、点图标出面板、和 Swift daemon 用 XPC），Pake 省下的时间会花在改 plist、重签和 GPL 上。SwiftUI `MenuBarExtra` 或一个自己拥有的 Tauri 工程更贴这个 UI。Pake 适合「先有一个窗口看进度」。

---

## 6. Agent 会话能不能冷热分层

会话文件里有提示词、工具输出、读过的源码，偶尔还有用户贴进去的密钥。远端仓库要按机密对待，不要和 app 镜像放同一套公开同步。下面路径都在用户主目录，macOS 上就是 `~`。

| 工具 | 会话位置 | 格式 | 搬走是否安全 |
|---|---|---|---|
| pi（[badlogic/pi-mono](https://github.com/badlogic/pi-mono)） | `~/.pi/agent/sessions/--<cwd>--/<时间>_<id>.jsonl`。[文档](https://pi.dev/docs/latest/sessions)、[格式](https://pi.dev/docs/latest/session-format) | JSONL 树，`id` / `parentId`，头行 `type:session` version 3。`parentSession` 是父文件的绝对路径 | **最适合做第一刀。** 官方允许 `PI_CODING_AGENT_SESSION_DIR`、`--session-dir`、`sessionDir`。没有保留期限，会一直涨。`--no-session` 不落盘 |
| Claude Code | `~/.claude/projects/<路径编码>/<session-id>.jsonl`，另有 `subagents/`、`tool-results/`、`file-history/`（[目录说明](https://code.claude.com/docs/en/claude-directory)，[会话](https://code.claude.com/docs/en/sessions)） | JSONL，格式随版本变，官方让外部用 `/export` 而不是自己解析 | 可以冷藏**已经写完**的 jsonl 和它的 `subagents/`、`tool-results/`。`CLAUDE_CONFIG_DIR` 把设置、会话、插件整棵搬走，**不要**指到远端，否则凭证一起走。默认 `cleanupPeriodDays` 30 天，恢复时若 mtime 仍旧，下次启动可能被扫掉 |
| Codex CLI | `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`（源码 `codex-rs/rollout/src/recorder.rs` 的 `precompute_new_rollout_path`） | JSONL rollout。旁边有 `state_*.sqlite` 索引 | jsonl 可以冷藏，但 resume 列表会扫文件并修 sqlite（[openai/codex#22037](https://github.com/openai/codex/issues/22037)）。有人测到约 4829 个文件、2.1GB、单文件约 141MB。`auth.json` 不能走 |
| Cursor IDE | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`，以及 `workspaceStorage/*/state.vscdb` | SQLite，`cursorDiskKV` 里 `bubbleId:` | **不适合分层。** 库在运行中带 WAL，拷贝会坏。体积常常是几百 MB 到数 GB，而且是热的 |
| Cursor CLI / agent | `~/.cursor/chats/<id>/<uuid>/store.db`（SQLite `blobs` + `meta`）加旁边的 `meta.json`；另一路是 `~/.cursor/projects/**/agent-transcripts/**/*.jsonl` | 官方文档没写死路径，来自磁盘观察（[ghinda](https://allaboutcoding.ghinda.com/where-ai-coding-clis-store-session-logs/)、[CodeBurn](https://codeburn.app/docs/data-locations)） | `store.db` 同样是活 SQLite。JSONL transcript 可以按「文件没被打开」冷藏。路径以后可能变 |

同类工具里，opencode 是 `~/.local/share/opencode/opencode.db`（SQLite，不要拆），Gemini CLI 是 `~/.gemini/tmp/*/chats/` 下的 JSON/JSONL。分层规则按格式走，不按产品名走。

**安全条件：**

- 只移动没有被进程打开的、非当前会话的 JSONL。追加写的最后一行可能不完整；Claude 的 hook 文档也写了 transcript 落后于内存（[hooks](https://code.claude.com/docs/en/hooks)）。
- 恢复必须写回原路径。pi 的 `--continue` 按 cwd 找目录；`parentSession` 和 fork 记的是绝对路径。Claude 的 `--resume <id>` 在配置目录的 projects 下找。Codex 按日期目录加 sqlite。
- 不要动：`~/.claude.json`、`~/.claude/.credentials.json`（或钥匙串项）、`~/.codex/auth.json`、`config.toml`、Cursor 的 `state.vscdb`、任何 `*.sqlite-wal`。
- 不要把这些目录本身放进 iCloud Drive 再让工具在线写。冲突副本（`file 2.jsonl`）会让 resume 读到半份会话。
- Claude 的 30 天清扫与「冷藏」是两套保留策略。冷藏前把 `cleanupPeriodDays` 加大，或者接受本地副本会被删、只有仓库里还有一份；恢复后要更新 mtime，否则刚拷回来就符合清除年龄。
- pi 在一次交换结束才写 jsonl，空的项目目录是正常的。看到空目录不要当成损坏去「修复」。

热层：当前会话文件、sqlite 索引、凭证、最近 N 天。冷层：更老的已关闭 JSONL（以及 Claude 的 tool-results / subagents）。恢复动作包在启动器里，在 `pi` / `claude` / `codex` 进程起来之前把文件放回去。pi 因为有独立的 session 目录变量，最适合试。

---

## 7. 对 docs/research.md 的修正

1. **`brctl download` / `brctl evict` 不能当 MVP 的接口。** Sonoma 14.4 前后已经没了。用 `FileManager` 的 download/evict。非沙盒 CLI 有公开实现，但仍应在 15 和 26 上各跑一次。
2. **`cp -c` 然后 evict 不是已知的零拷贝。** 域内克隆在 evict 后失去共享，配额按两份计。域外克隆仍需实测。缓存先真拷贝。
3. **Keep Downloaded 是 xattr，没有 FileManager API**，而且是单机效果。
4. **上传完成**要 `isUploaded && !isUploading && 无 uploadingError`，不能只看 `brctl status`。下载进度不要做成字节条。
5. **不要 attach dataless DMG。** 先等到分配大小起来。`mmap` 死锁是已知类故障。
6. **ULMO 更小但创建慢、随机读走用户态 helper。** 已发表的一组数字是 327MB app：ULMO 99MB/创建 43 秒，ULFO 130MB/7 秒。50–70% 不是通例。远端 ULMO、本地缓存 ULFO 或 UDRO。
7. **ASIF / DiskImageKit 不是压缩 app 镜像的下一档。** 它们服务虚拟化。macOS 27 弃用 `hdiutil`，新代码应能走 `diskutil image`，但 15/26 仍是 `hdiutil`。
8. **AppPorts 不检测退出，也不挂 DMG。** 退出轮询的先例是 Playpen，而且它的进程名匹配不能学。URL scheme 在 AppPorts 的 plist 里有，原生启动器却不转发。
9. **壳的 bundle id 必须加后缀。** Playpen 沿用原 id，会和真 app 抢 LS/TCC。
10. **`lsregister -u` 在 detach 之前。** `-nobrowse` 已经让 Spotlight 不索引，这是优点。
11. **Gatekeeper/XProtect 发生在 `open`，不发生在 `hdiutil attach`。** `detach -force` 会让还映射着映像的进程 `SIGBUS` / `EIO`，只做超时后的最后手段。
12. **TCC 按 bundle id + DR，不按路径。** 辅助功能类开关仍可能要用户重拨。不要重签真 app。MAS 不要放进自建 DMG。
13. **Pake 能做托盘窗口，不能直接做无 Dock 的菜单栏面板，也没有现成的本地 IPC。** 许可证是 GPL-3.0。localhost HTTP 连 daemon 是正道。签名要 Developer ID，他们的 CI 用 `PAKE_*` 写 Tauri 的 `signingIdentity`。

## 8. 设计建议（只约束方向）

- 壳：Developer ID，bundle id 加稳定后缀，`LSUIElement`，plist 从真 app 拷文档类型和 URL scheme，再删更新器键。启动器自己处理文件和 URL，失败时不要留下挂载。不要 ad-hoc 重签真 app，不要 Contents 符号链接。
- 运行：物化并校验之后再 attach `-readonly -nobrowse`。退出条件是挂载点上没有剩余进程和打开文件，延迟后再 detach。detach 前 `lsregister -u` 真 app。`-force` 不是正常路径。
- 仓库：iCloud 单文件 DMG，ULMO；本地缓存独立拷贝，需要速度再转 ULFO/UDRO。pin 只用本机 xattr。上传完成看三个 URL 资源键。
- 兼容：MAS、特权 helper、系统扩展走还原模式。只读映像上的自更新当成「需要重新打包」，不要 shadow 着让它改。
- UI：进度窗口可以用 Pake 加载 `127.0.0.1`。菜单栏本体优先 SwiftUI。Pake 壳若对外分发，先处理 GPL。
- 会话冷藏：从 pi 的 session 目录开始，只移动已关闭的 JSONL，恢复到原路径，排除一切凭证和 SQLite。
