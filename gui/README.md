# 256isenough.app (menu-bar app)

The GUI is a native AppKit app, `Sources/IsenoughMac`. It has no Dock icon
(`LSUIElement`). It puts an item in the menu bar with **Open Dashboard**,
**Copy Dashboard URL**, the version, and **Quit**.

On launch it starts the same loopback server as `isenough ui`
(`LoopbackUIServer` with `ManagementUI.respond`) inside the app process, on
`127.0.0.1` with a fresh random token, and shows
`http://127.0.0.1:<port>/?token=<token>` in a WKWebView window. Links that leave
the dashboard open in the default browser. Closing the window keeps the app in
the menu bar; reopening the app (or the menu item) shows the window again.

The page itself lives in `Sources/isenough/web` and is shared with `isenough ui`.

## Build

```sh
scripts/build-app.sh                      # universal (arm64 + x86_64)
ISENOUGH_ARCHS=arm64 scripts/build-app.sh # one architecture, faster
open build/256isenough.app
```

The script runs `swift build -c release --arch arm64 --arch x86_64`, stamps the
version with `scripts/gen-version.sh`, and assembles:

```
build/256isenough.app/Contents/
  Info.plist                  from packaging/Info.plist (io.github.s546126.256isenough)
  MacOS/256isenough           menu-bar app (IsenoughMac)
  MacOS/isenough              CLI and engine
  MacOS/isenough-stub         launcher template copied into generated stubs
  Resources/web/              management page
  Resources/LICENSE, THIRD_PARTY_NOTICES.md, PRIVACY.md
```

The CLI and stub sit next to the main executable because the engine looks for
`isenough-stub` beside the running binary, and because the app forwards any
command-line invocation of itself (such as the detached `hook watch` after a
restore-mode launch) to `MacOS/isenough`. The script fails when a binary links a
library outside `/usr/lib` or `/System`, and ends with a `lipo -archs` check.

The bundle is ad-hoc signed. `scripts/release-sign.sh` signs it with a Developer
ID, notarizes, staples, and writes the DMG and tarball.

During development you can also run `swift run IsenoughMac`. It finds the page in
the CLI's SwiftPM resource bundle next to the build products, or in
`ISENOUGH_WEB_ROOT`.

## Isolated test run

Point every path at a temporary folder before you start the app from a terminal,
so it never reads your real repo or state:

```sh
T=$(mktemp -d)
export ISENOUGH_REPO_PATH=$T/repo ISENOUGH_CACHE_DIR=$T/cache ISENOUGH_STATE_DIR=$T/state \
       ISENOUGH_MOUNT_ROOT=$T/mnt ISENOUGH_STUB_DIR=$T/apps
build/256isenough.app/Contents/MacOS/isenough init
build/256isenough.app/Contents/MacOS/256isenough
```

## Licensing

The previous Pake wrapper (GPL-3.0) is gone. The app uses only Apple frameworks
and the MIT-licensed code in this repository, plus the libraries in
`THIRD_PARTY_NOTICES.md`.
