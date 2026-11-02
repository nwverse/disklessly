#!/usr/bin/env bash
# Build build/Disklessly.app: the native menu-bar app with the disklessly CLI and
# the stub launcher inside it.
#
#   Contents/MacOS/DisklesslyApp  menu-bar app (DisklesslyMac), main executable
#   Contents/MacOS/disklessly        CLI and engine
#   Contents/MacOS/disklessly-stub   launcher template copied into generated stubs
#   Contents/MacOS/rclone          pinned rclone for cloud drives (scripts/fetch-rclone.sh)
#   Contents/Resources/web/        management page
#   Contents/Resources/AppIcon.icns  app icon (Resources/AppIcon.icns, see scripts/make-icon.sh)
#
# The CLI and the stub sit beside the main executable because the engine looks
# for disklessly-stub next to the running binary.
#
# Environment:
#   DISKLESSLY_ARCHS      space separated, default "arm64 x86_64" (universal)
#   DISKLESSLY_BUILD_DIR  output folder, default <repo>/build
#   DISKLESSLY_KEEP_VERSION=1  leave the stamped EngineInstall.swift in place
#   DISKLESSLY_NO_RCLONE=1     leave rclone out (cloud drives then use rclone from PATH)
#
# The bundle is ad-hoc signed so it runs on this Mac. scripts/release-sign.sh
# re-signs it with a Developer ID for distribution.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${DISKLESSLY_BUILD_DIR:-$ROOT/build}"
APP="$OUT/Disklessly.app"
read -r -a ARCHS <<<"${DISKLESSLY_ARCHS:-arm64 x86_64}"
[[ "$(uname -s)" == Darwin ]] || { echo "build-app: needs macOS" >&2; exit 69; }

VERSION_FILE="$ROOT/Sources/DisklesslyEngine/EngineInstall.swift"
SAVED="$(mktemp)"
cp "$VERSION_FILE" "$SAVED"
restore_version() {
  if [[ "${DISKLESSLY_KEEP_VERSION:-}" != 1 ]]; then cat "$SAVED" >"$VERSION_FILE"; fi
  rm -f "$SAVED"
}
trap restore_version EXIT
bash "$ROOT/scripts/gen-version.sh"
VERSION="$(sed -n 's/^    public static let version = "\(.*\)"$/\1/p' "$VERSION_FILE" | head -n 1)"
COMMIT="$(sed -n 's/^    public static let commit = "\(.*\)"$/\1/p' "$VERSION_FILE" | head -n 1)"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"

ARCH_FLAGS=()
for arch in "${ARCHS[@]}"; do ARCH_FLAGS+=(--arch "$arch"); done
cd "$ROOT"
swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"
for product in DisklesslyMac disklessly disklessly-stub; do
  [[ -x "$BIN/$product" ]] || { echo "build-app: $BIN/$product was not built" >&2; exit 70; }
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DisklesslyMac" "$APP/Contents/MacOS/DisklesslyApp"
cp "$BIN/disklessly" "$APP/Contents/MacOS/disklessly"
cp "$BIN/disklessly-stub" "$APP/Contents/MacOS/disklessly-stub"
HELPERS=(disklessly-stub disklessly)
if [[ "${DISKLESSLY_NO_RCLONE:-}" != 1 ]]; then
  DISKLESSLY_RCLONE_DIR="$OUT/rclone" bash "$ROOT/scripts/fetch-rclone.sh"
  cp "$OUT/rclone/rclone" "$APP/Contents/MacOS/rclone"
  HELPERS=(rclone "${HELPERS[@]}")
fi
cp -R "$ROOT/Sources/disklessly/web" "$APP/Contents/Resources/web"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/PRIVACY.md" "$APP/Contents/Resources/"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
# App icon: Resources/AppIcon.icns is committed; regenerate it only if it is missing.
ICON="$ROOT/Resources/AppIcon.icns"
[[ -s "$ICON" ]] || bash "$ROOT/scripts/make-icon.sh" "$ROOT/Resources"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -replace CFBundleIconFile -string "AppIcon" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' >"$APP/Contents/PkgInfo"
test -s "$APP/Contents/Resources/web/index.html"

# Nothing may link against Homebrew or another machine-local library.
for exe in "$APP/Contents/MacOS/"*; do
  if /usr/bin/otool -L "$exe" | grep -E '^[[:space:]]' | grep -Ev '^[[:space:]]+(/usr/lib/|/System/Library/)' | grep -q .; then
    echo "build-app: $exe links a library outside the OS:" >&2
    /usr/bin/otool -L "$exe" >&2
    exit 70
  fi
done

# Inside-out ad-hoc signature. The release identity replaces it later.
for exe in "${HELPERS[@]}"; do
  /usr/bin/codesign --force --sign - "$APP/Contents/MacOS/$exe"
done
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"

status=0
for exe in DisklesslyApp "${HELPERS[@]}"; do
  have="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/$exe")"
  for arch in "${ARCHS[@]}"; do
    if [[ " $have " != *" $arch "* ]]; then
      echo "build-app: $exe is missing $arch (has: $have)" >&2
      status=1
    fi
  done
  echo "lipo -archs $exe: $have"
done
[[ $status -eq 0 ]] || exit 70
echo "built $APP ($VERSION, $COMMIT)"
