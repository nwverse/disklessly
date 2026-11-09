# Disklessly.app (menu-bar app)

The GUI is a native AppKit app, `Sources/DisklesslyMac`. It has no Dock icon
(`LSUIElement`). It puts an item in the menu bar with **Open Dashboard**,
**Copy Dashboard URL**, the version, and **Quit**.

On launch it starts the same loopback server as `disklessly ui`
(`LoopbackUIServer` with `ManagementUI.respond`) inside the app process, on
`127.0.0.1` with a fresh random token, and shows
`http://127.0.0.1:<port>/?token=<token>` in a WKWebView window. Links that leave
the dashboard open in the default browser. Closing the window keeps the app in
the menu bar; reopening the app (or the menu item) shows the window again.

The page itself lives in `Sources/disklessly/web` and is shared with `disklessly ui`.

## Build

```sh
scripts/build-app.sh                      # universal (arm64 + x86_64)
DISKLESSLY_ARCHS=arm64 scripts/build-app.sh # one architecture, faster
open build/Disklessly.app
```

The script runs `swift build -c release --arch arm64 --arch x86_64`, stamps the
version with `scripts/gen-version.sh`, and assembles:

```
build/Disklessly.app/Contents/
  Info.plist                  from packaging/Info.plist (io.github.s546126.disklessly)
  MacOS/Disklessly           menu-bar app (DisklesslyMac)
  MacOS/disklessly              CLI and engine
  MacOS/disklessly-stub         launcher template copied into generated stubs
  Resources/web/              management page
  Resources/AppIcon.icns      app icon (CFBundleIconFile), from Resources/AppIcon.icns
  Resources/LICENSE, THIRD_PARTY_NOTICES.md, PRIVACY.md
```

The CLI and stub sit next to the main executable because the engine looks for
`disklessly-stub` beside the running binary, and because the app forwards any
command-line invocation of itself (such as the detached `hook watch` after a
restore-mode launch) to `MacOS/disklessly`. The script fails when a binary links a
library outside `/usr/lib` or `/System`, and ends with a `lipo -archs` check.

The bundle is ad-hoc signed. `scripts/release-sign.sh` signs it with a Developer
ID, notarizes, staples, and writes the DMG and tarball.

During development you can also run `swift run DisklesslyMac`. It finds the page in
the CLI's SwiftPM resource bundle next to the build products, or in
`DISKLESSLY_WEB_ROOT`.

## Isolated test run

Point every path at a temporary folder before you start the app from a terminal,
so it never reads your real repo or state:

```sh
T=$(mktemp -d)
export DISKLESSLY_REPO_PATH=$T/repo DISKLESSLY_CACHE_DIR=$T/cache DISKLESSLY_STATE_DIR=$T/state \
       DISKLESSLY_MOUNT_ROOT=$T/mnt DISKLESSLY_STUB_DIR=$T/apps
build/Disklessly.app/Contents/MacOS/disklessly init
build/Disklessly.app/Contents/MacOS/Disklessly
```

## Licensing

The previous Pake wrapper (GPL-3.0) is gone. The app uses only Apple frameworks
and the MIT-licensed code in this repository, plus the libraries in
`THIRD_PARTY_NOTICES.md`.
