# Disklessly 使用指南 · User Guide

中文在前，[English below](#english).

---

## 目录

1. [它做什么](#它做什么)
2. [安装](#安装)
3. [初始化仓库 `init`](#初始化仓库-init)
4. [挑选要卸载的应用 `recommend`](#挑选要卸载的应用-recommend)
5. [卸载应用 `pack`](#卸载应用-pack)
6. [通过替身启动](#通过替身启动)
7. [缓存：固定、预取、清除](#缓存固定预取清除)
8. [把应用放回来 `unpack`](#把应用放回来-unpack)
9. [仓库后端：iCloud、SMB/NFS、WebDAV、OpenList](#仓库后端)
10. [多台 Mac 共用一个仓库](#多台-mac-共用一个仓库)
11. [菜单栏应用与仪表盘](#菜单栏应用与仪表盘)
12. [编程助手会话 `sessions`](#编程助手会话-sessions)
13. [排查问题 `doctor`](#排查问题-doctor)
14. [卸载 Disklessly](#卸载-Disklessly)
15. [隐私](#隐私)
16. [挂载生命周期与仓库归属](#挂载生命周期与仓库归属)

## 它做什么

Disklessly 把不常用的 Mac 应用从 `/Applications` 搬到你自己的「仓库」里：一个本地文件夹、
iCloud Drive、NAS 共享（SMB/NFS）或 WebDAV/OpenList 服务器。每个应用被打成一个经过校验的
DMG 镜像，原位置只留下一个同名同图标的小**替身（stub）**。

双击替身时，Disklessly 会：下载镜像（或直接用本机缓存）→ 校验 SHA-256 → 只读挂载 → 启动应用。
用替身打开的文档和链接会原样转交给应用。退出应用后，镜像在一段延迟（默认 120 秒）后自动卸载。

两种运行模式：

- **mount（挂载）**：应用直接从只读镜像运行。大多数应用默认用这种模式。
- **restore（还原）**：本次使用期间把应用复制回原位置，退出后再放回仓库，全程有日志保护。
  Mac App Store 应用默认使用这种模式，也可以用 `--mode restore` 指定。

## 安装

**应用（推荐）**：从 [Releases](https://github.com/s546126/disklessly/releases) 下载
`Disklessly-<版本>.dmg`，把 Disklessly 拖进「应用程序」并打开。菜单栏会出现一个图标，选择
**Open Dashboard** 打开仪表盘。命令行工具在应用包里：

```sh
sudo ln -s /Applications/Disklessly.app/Contents/MacOS/disklessly /usr/local/bin/disklessly
```

**Homebrew**：`brew install --cask disklessly`（应用 + 命令行），或 `brew install disklessly-cli`（只装命令行）。

**压缩包**：`disklessly-<版本>-macos-universal.tar.gz` 内含 `bin/disklessly`、`bin/disklessly-stub`、
`share/disklessly/web`，请保持这个目录结构。下载后可用 `SHA256SUMS` 校验。

系统要求：macOS 13 或更新版本，Apple 芯片或 Intel。

**权限**：替换 `/Applications` 中的应用需要「系统设置 › 隐私与安全性 › App 管理」权限。请授予
Disklessly.app；如果你在终端里用命令行，也要授予你的终端。没有这个权限时 `pack` / `unpack`
会报权限错误，应用保持原样。仓库或应用在受保护位置时，可能还需要「完全磁盘访问权限」。

## 初始化仓库 `init`

```sh
disklessly init                                  # 默认仓库：iCloud Drive/Disklessly
disklessly init --root /Volumes/NAS/Disklessly  # 或任意文件夹
```

`init` 会打印仓库、缓存、替身的位置和缓存配额（默认 20 GiB）。默认位置：

| 内容 | 位置 |
| --- | --- |
| 仓库（默认） | `~/Library/Mobile Documents/com~apple~CloudDocs/Disklessly` |
| 缓存 | `~/Library/Caches/Disklessly/` |
| 本机状态、配置、引擎副本 | `~/Library/Application Support/Disklessly/` |
| 替身 | `/Applications` |

## 挑选要卸载的应用 `recommend`

```sh
disklessly recommend                    # 体积大、很久没用的应用
disklessly recommend --min-size 500M --min-idle-days 60 --limit 10
disklessly recommend --all              # 也列出通常应保留的应用
```

按体积和闲置天数排序（默认只看 100 MB 以上的应用）。会自动跳过系统应用、正在运行的应用，
以及应当保留在本机的东西：登录项、菜单栏常驻程序、Xcode 等开发工具链。如果另一台 Mac 已经把同一个
应用放进仓库，会注明「无需上传」。

## 卸载应用 `pack`

```sh
disklessly pack "/Applications/Some App.app"
disklessly pack "/Applications/Some App.app" --keep-original   # 保留原件为 Some App.256orig.app
disklessly pack "/Applications/Some App.app" --mode restore
```

`pack` 依次：检查空间和应用是否在运行 → 制作镜像 → 校验 → 上传 → 确认仓库中的副本可用 →
**最后**才用替身替换应用。仓库里的镜像缺失、仍是占位文件或校验不符时，`pack` 以退出码 5 终止，应用不动。

输出会说明镜像大小、是复用了仓库已有镜像还是新上传、替身的位置、原件的去向。建议先拿一个可以重新安装的应用试一试。

## 通过替身启动

像平常一样从访达、启动台、Spotlight 或程序坞打开替身即可。命令行等价写法：

```sh
disklessly launch "Some App"
disklessly launch "Some App" --doc ~/Desktop/file.ext   # 用应用打开文档
disklessly launch "Some App" --url https://example.com
disklessly restore "Some App"                            # 强制以 restore 模式启动
```

第一次打开或缓存被清理后需要下载，速度取决于你的仓库。每次启动都会先校验 SHA-256；
iCloud 中尚未下载到本机的文件绝不会被直接挂载。

restore 模式下如果你修改了应用（例如应用自我更新），退出后会提示需要处理：

```sh
disklessly resolve "Some App" --keep-updated   # 保留更新后的版本
disklessly resolve "Some App" --export ~/Desktop
disklessly resolve "Some App" --discard
```

## 缓存：固定、预取、清除

```sh
disklessly list                 # 已卸载的应用
disklessly status [APP]         # 缓存用量和每个应用的状态
disklessly pin APP              # 固定：镜像一直留在缓存，不会被自动清理
disklessly unpin APP
disklessly prefetch APP         # 提前下载，比如上飞机前
disklessly evict APP            # 删除本机缓存的镜像，仓库中的副本不受影响
disklessly gc [--dry-run]       # 整理：补完中断的操作、清理无引用镜像（进仓库回收站，保留 7 天）、按配额修剪缓存
disklessly evict-local          # 删除已确认上传完成的 iCloud 本地副本
disklessly caches [--apply]     # 已卸载应用留在 ~/Library/Caches 的缓存：默认只列出，--apply 才清空
```

`caches` 只清空 `~/Library/Caches/<bundleId>`、`~/Library/Caches/<应用名>` 和沙盒容器里的 `Data/Library/Caches`；
Application Support 和其他应用数据不会动，正在运行的应用会跳过。仪表盘“磁盘占用”卡片分析完后也有“清理应用缓存”按钮。

缓存超过配额时按最近最少使用（LRU）清理；已固定、正在挂载或正在使用的镜像不会被清理。
下载会在磁盘剩余空间低于下限（默认 15 GiB）时拒绝执行（退出码 8）。

## 把应用放回来 `unpack`

```sh
disklessly unpack "Some App"                 # 用真正的应用替换替身
disklessly unpack "Some App" --to ~/Desktop  # 只复制一份出来，替身保留
```

放回前会校验应用目录树哈希和代码签名。镜像仍保留在仓库中，之后可以再次 `pack`（不需要重新上传）。

## 仓库后端

- **本地文件夹**：`disklessly init --root /path/to/folder`。
- **iCloud Drive**：默认。读取前会自动触发下载并限时等待；列目录也有超时。如果从访达打开替身时长时间卡住，
  请在「隐私与安全性 › 文件和文件夹」中给相应应用授权。
- **SMB / NFS**：

  ```sh
  disklessly backend add smb --host nas.local --share apps --user alice --mount /Volumes/apps --id nas --password-stdin
  disklessly backend add nfs --host nas.local --export /export/apps --mount /Volumes/nfs --id nfs
  disklessly backend use nas
  ```

- **WebDAV**：

  ```sh
  disklessly backend add webdav --url https://nas.example/dav/Disklessly --user alice --id dav --password-stdin
  ```

- **OpenList / AList 3**：

  ```sh
  disklessly backend add openlist --url http://nas.local:5244 --root /Disklessly --user alice --id ol --password-stdin
  ```

密码只从标准输入读取，存入「钥匙串」，不会写进 `config.json`，也不会出现在命令行上。
`disklessly backend list` 列出已配置的后端。细节见 [backends.md](backends.md)。

## 多台 Mac 共用一个仓库

让每台 Mac 指向同一个仓库（同一个 `--root`，或都用默认的 iCloud Drive 文件夹）。

- 镜像一次写入、按 bundle id、版本、构建号、架构和内容哈希命名，所以同一个应用在两台 Mac 上只存一份，
  第二台 `pack` 时不会再上传。
- 每台 Mac 只写自己的 `devices/<id>.json`。`gc` 绝不会删除任何一台 Mac 还在使用的镜像，哪怕它已离线数月。
- 固定、缓存、启动状态只属于本机。

```sh
disklessly devices                      # 列出共享仓库的 Mac 以及它们在用的镜像
disklessly devices rename "书房 Mac mini"
disklessly devices forget DEVICEID --yes   # 永久不再使用的 Mac
```

## 菜单栏应用与仪表盘

打开 Disklessly.app 后，菜单栏出现一个图标（没有程序坞图标），菜单中有：

- **Open Dashboard**：在独立窗口中打开仪表盘。
- **Copy Dashboard URL**：复制带令牌的地址，可在浏览器里打开。
- 版本号、**Quit Disklessly**。

仪表盘显示后端状态、缓存用量和配额、已卸载应用（图标、大小、状态）、固定、共享仓库的其他 Mac，
以及推荐列表；可以直接在页面上打开、预取、固定、清除缓存、放回应用（卸载新应用目前请用 `disklessly pack`）。界面为中英双语，随系统切换浅色/深色。

命令行也能打开同一个页面：`disklessly ui --open`（在浏览器中打开）或 `disklessly ui --json`（打印 `url`、`port`、`token`）。
仪表盘只监听 `127.0.0.1`，并且每次启动都使用新的随机令牌，局域网中的其他机器无法访问。

## 编程助手会话 `sessions`

`disklessly sessions` 把很久没动的 Claude Code、Codex、pi 会话记录（JSONL）归档到仓库里的只写一次的 zstd 段中，
并在本机保留一个可搜索的索引。默认只是演练，加 `--apply` 才会上传；上传并校验成功后，**本地的 JSONL 会被删除**，
之后这些会话只存在于仓库中。

```sh
disklessly sessions                 # 演练：列出将要归档的文件
disklessly sessions --apply         # 归档，并删除已归档的本地文件
disklessly sessions key init        # 创建会话加密密钥（保存在钥匙串）
disklessly sessions --apply --encrypt
disklessly sessions search QUERY    # 搜索已归档的会话
disklessly sessions restore ID      # 把会话写回原来的位置
```

加密的会话段只能用钥匙串里的那把密钥解开，丢失密钥就无法恢复。详见 [sessions.md](sessions.md)。

## 排查问题 `doctor`

```sh
disklessly doctor          # 逐项检查并实时打印结果
disklessly doctor --fix    # 回放本机未完成的 unpack / restore 日志
```

检查项包括配置、未完成的日志、后端是否可达、iCloud 冲突副本、哪些仓库文件在本地等，每项都有时间上限
（`DISKLESSLY_DOCTOR_TIMEOUT`）。常见情况：

| 现象 | 处理 |
| --- | --- |
| `pack`/`unpack` 报权限错误 | 在「App 管理」中授权 Disklessly.app 和你的终端 |
| 替身打开后长时间没反应（iCloud） | 检查网络；在「文件和文件夹」中授权；`disklessly prefetch APP` 提前下载 |
| 退出码 4 | 后端不可达（NAS 离线、WebDAV 无法连接） |
| 退出码 5 | 镜像校验失败或仍是占位文件；不会挂载或替换任何东西 |
| 退出码 8 | 磁盘剩余空间不足 |
| 退出码 14 | 需要处理，例如 `disklessly resolve APP` |
| `/Applications/.disklessly-original-*.app` 残留 | `disklessly cleanup-backups`（校验后删除，只弹一次管理员授权） |
| 升级后替身仍用旧引擎 | `disklessly install-engine`，再对每个应用 `disklessly stub refresh --app ID` |

加 `--json` 获得机器可读输出；设置 `DISKLESSLY_DEBUG=1` 可在错误中附带底层细节。

## 卸载 Disklessly

> **警告：删除仓库会永久丢失数据。** `pack` 之后，仓库里的镜像就是这个应用唯一的副本；
> `disklessly sessions --apply` 归档的编程助手会话记录也只存在于仓库中（本地 JSONL 已删除）。
> 删除仓库文件夹前没有放回的应用和没有恢复的会话都无法找回。

1. `disklessly list`，对每个想留下的应用执行 `disklessly unpack APP`（或在仪表盘里点「放回」）。
   再次运行 `disklessly list` 和 `disklessly status`，确认已经没有替身。
2. 如果用过 `disklessly sessions --apply`：用 `disklessly sessions search QUERY` 找到需要的会话，
   逐个执行 `disklessly sessions restore ID` 写回原位置。加密的会话段需要钥匙串里的会话密钥，
   恢复完成前不要删除这把密钥。
3. 从菜单栏退出 Disklessly，把它移到废纸篓（或 `brew uninstall --cask Disklessly`）。
4. 删除 `~/Library/Application Support/Disklessly/`（含会话索引）和 `~/Library/Caches/Disklessly/`。
5. 只有在完成第 1、2 步并且没有其他 Mac 在用时，才删除仓库文件夹。

注意：第 4 步会删除替身依赖的引擎副本，之后没有放回的替身将无法打开。

## 免费版与授权

免费版**最多同时卸载 2 个应用**。已卸载应用的启动、还原（`unpack`）、清除缓存、卸载镜像永远不需要授权，只有新增 `pack` 时检查数量；重新打包一个已卸载的应用不算新增。输入授权码后不再限制数量：

```sh
disklessly license                    # 查看当前是免费版还是已授权
disklessly license activate DSL1.…    # 激活
disklessly license deactivate         # 移除
```

授权码在本机离线验证，不会联网。买断码不过期；限时码有最后有效日期，过期后免费版限额重新生效，已卸载的应用照常使用。仪表盘里的"授权"卡片也能激活和移除。

## 隐私

没有遥测、统计、崩溃上报，也不检查更新。Disklessly 只和你配置的仓库通信，项目本身不运行任何服务器。
NAS / WebDAV 密码和会话加密密钥保存在钥匙串中。详见 [PRIVACY.md](../PRIVACY.md)。

## 挂载生命周期与仓库归属

- `disklessly evict APP`：已固定的应用会被拒绝（退出码 9，reason `pinned`）；加 `--force` 可仍然清除缓存（固定状态保留）。正在挂载或使用中的镜像即使加 `--force` 也不会清除。
- `disklessly detach APP [--force]`：立即卸载一个应用的镜像，不必等待卸载延迟；应用仍在运行时会拒绝。
- `disklessly reap [--dry-run]`：卸载挂载目录下所有者已退出的遗留挂载。`launch`、`gc` 和 `doctor --fix` 也会自动回收。
- 替身按仓库区分：`stub.json` 记录 `repoId`，其他仓库不会认领它。旧替身可用 `disklessly stub refresh --all` 补写。

---

<a id="english"></a>
## English

### What it does

Disklessly moves Mac apps you rarely use out of `/Applications` into a repo you
control (a local folder, iCloud Drive, an SMB/NFS share, or a WebDAV/OpenList
server). Each app becomes a verified DMG image, and a small signed **stub** with
the same name and icon takes its place. Opening the stub downloads the image (or
uses the cache), checks its SHA-256, mounts it read-only, and starts the app.
Documents and URLs are passed through. After you quit, the image is detached
after a delay (120 s by default).

Two modes: **mount** runs the app from the read-only image; **restore** copies it
back for the session under a journal and returns it after quit (the default for
Mac App Store apps, or `--mode restore`).

### Install

- **App:** download `Disklessly-<version>.dmg` from Releases, drag it to
  Applications, open it, and choose **Open Dashboard** from the menu-bar item.
  Link the CLI: `sudo ln -s /Applications/Disklessly.app/Contents/MacOS/disklessly /usr/local/bin/disklessly`.
- **Homebrew:** `brew install --cask disklessly`, or `brew install disklessly-cli` for the CLI only.
- **Tarball:** keep the `bin/` and `share/disklessly/web` layout; verify with `SHA256SUMS`.

macOS 13 or later. Grant **App Management** (System Settings > Privacy & Security)
to Disklessly.app and to your terminal so `pack` and `unpack` can replace apps.

### Everyday commands

```sh
disklessly init [--root DIR]                 # repo in iCloud Drive by default
disklessly recommend                         # big apps you have not used lately
disklessly pack "/Applications/App.app"      # image, verify, upload, then replace with a stub
disklessly launch App [--doc FILE] [--url URL]
disklessly list | status [APP]
disklessly pin APP | unpin APP | prefetch APP | evict APP
disklessly gc [--dry-run]
disklessly caches [--apply]                  # caches offloaded apps left in ~/Library/Caches (dry run without --apply)
disklessly unpack App [--to DIR]             # put the real app back (or copy it out)
disklessly doctor [--fix]
disklessly ui --open                         # dashboard in your browser
```

Nothing is replaced until a verified image is in the repo; a missing or
mismatched image stops `pack` with exit 5 and leaves the app alone.

### Backends

`disklessly backend add smb|nfs|webdav|openlist ... --password-stdin`, then
`disklessly backend use ID`. Passwords go to the Keychain, never to `config.json`
or a command line. See [backends.md](backends.md).

### Several Macs

Point every Mac at the same repo. Images are write-once and content-addressed, so
an app packed on one Mac is not uploaded again from another. Each Mac writes only
its own device file, and `gc` keeps every image any Mac still uses.
`disklessly devices`, `devices rename NAME`, `devices forget ID --yes`.

### Menu-bar app

Disklessly.app lives in the menu bar (no Dock icon) with **Open Dashboard**,
**Copy Dashboard URL**, the version, and **Quit**. The dashboard shows the backend,
cache use against the quota, packed apps, pins, other Macs, and recommendations,
and can open, prefetch, pin, evict, and unpack apps (packing a new app is `disklessly pack` for now). It listens only on `127.0.0.1` with a fresh
random token.

### Coding-agent sessions

`disklessly sessions` (dry run by default) archives cold Claude Code, Codex, and pi
transcripts into write-once zstd segments in the repo and keeps a local search
index. `--apply` uploads them and then **deletes the local JSONL**, so archived
sessions live only in the repo. `sessions key init` plus `--encrypt` encrypts
segments with a Keychain key; without that key they cannot be read.
`disklessly sessions search QUERY` finds them and `disklessly sessions restore ID`
writes one back. See [sessions.md](sessions.md).

### Troubleshooting

Run `disklessly doctor` (each check is time-bounded) and `doctor --fix` to replay
interrupted local journals. Exit codes: 4 backend unreachable, 5 integrity, 8 no
space, 9 busy, 14 needs attention (`disklessly resolve APP`). `DISKLESSLY_DEBUG=1`
adds Foundation error details. After an upgrade run `disklessly install-engine` and
`disklessly stub refresh --app ID` for each app.

### Uninstall

> **Warning: deleting the repo destroys data for good.** After `pack`, the repo
> image is the only copy of that app, and transcripts archived by
> `disklessly sessions --apply` exist only in the repo (their local JSONL was
> deleted). Apps you did not unpack and sessions you did not restore cannot be
> recovered once the repo folder is gone.

1. Run `disklessly list` and `disklessly unpack APP` for every app you want back.
   Run `disklessly list` and `disklessly status` again to check no stubs are left.
2. If you used `disklessly sessions --apply`, find what you need with
   `disklessly sessions search QUERY` and run `disklessly sessions restore ID` for
   each one. Encrypted segments need the session key in the Keychain; keep it
   until the restore is done.
3. Quit Disklessly from the menu bar and move it to the Trash.
4. Delete `~/Library/Application Support/Disklessly/` (it holds the session
   index) and `~/Library/Caches/Disklessly/`. Stubs you did not unpack stop
   working once the engine copy is gone.
5. Delete the repo folder only after steps 1 and 2, and only if no other Mac uses it.

### Free version and license

The free version offloads up to 2 apps at once. Starting, restoring (`unpack`), evicting and detaching apps
you already offloaded never needs a license; only `pack` checks the limit, and re-packing an offloaded app
is not a new app. A license code lifts the limit: `disklessly license activate CODE` (also `license`,
`license deactivate`, and the License card in the dashboard). Codes are verified offline. A buyout code does
not expire; a promo code has a last day, after which the free limit applies again.

### Privacy

No telemetry, analytics, crash reporting, or update checks. Disklessly talks only
to the repo you configure. See [PRIVACY.md](../PRIVACY.md).

### Mount lifecycle and repo scoping

- `disklessly evict APP` refuses a pinned app (exit 9, reason `pinned`); `--force` evicts it anyway and keeps the pin. A mounted or in-use image is never evicted, even with `--force`.
- `disklessly detach APP [--force]` detaches an app's image now instead of waiting for the detach delay; it refuses while the app is running.
- `disklessly reap [--dry-run]` detaches images left mounted after their owner died. `launch`, `gc`, and `doctor --fix` also reap.
- Each stub records its repo (`repoId` in `stub.json`), so another repo never claims it. `disklessly stub refresh --all` stamps older stubs.
