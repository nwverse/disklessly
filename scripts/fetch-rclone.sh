#!/usr/bin/env bash
# Download the pinned rclone release for macOS, check its SHA-256, and write a universal
# binary to build/rclone/rclone (plus its license). scripts/build-app.sh copies it into
# Disklessly.app/Contents/MacOS/rclone.
#
# Bump VERSION and both digests together; RcloneTool.bundledVersion names the same version.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${DISKLESSLY_RCLONE_DIR:-$ROOT/build/rclone}"
VERSION="v1.75.2"
declare -a ARCH_NAMES=(arm64 amd64)
digest() {
  case "$1" in
    arm64) echo 610ab7d48615135dfc60b763858b11a426a0d3d1160c1bb76fb0ae6011b02edd ;;
    amd64) echo 574e1f31cf1c464e5fb0325cb66fcbdeaf1efa1802bd9b17f13c256fd74b6561 ;;
  esac
}

if [[ -x "$OUT/rclone" && "$(cat "$OUT/VERSION" 2>/dev/null)" == "$VERSION" ]]; then
  echo "fetch-rclone: $OUT/rclone is already $VERSION"
  exit 0
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
slices=()
for arch in "${ARCH_NAMES[@]}"; do
  name="rclone-$VERSION-osx-$arch"
  zip="$WORK/$name.zip"
  curl -fsSL --retry 3 -o "$zip" "https://github.com/rclone/rclone/releases/download/$VERSION/$name.zip"
  have="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
  if [[ "$have" != "$(digest "$arch")" ]]; then
    echo "fetch-rclone: $name.zip has SHA-256 $have, expected $(digest "$arch")" >&2
    exit 65
  fi
  mkdir -p "$WORK/$arch"
  unzip -q "$zip" -d "$WORK/$arch"
  slices+=("$WORK/$arch/$name/rclone")
  cp "$WORK/$arch/$name/LICENSE" "$WORK/LICENSE" 2>/dev/null || true
done
mkdir -p "$OUT"
/usr/bin/lipo -create "${slices[@]}" -output "$OUT/rclone"
chmod 755 "$OUT/rclone"
[[ -s "$WORK/LICENSE" ]] && cp "$WORK/LICENSE" "$OUT/LICENSE-rclone"
echo "$VERSION" >"$OUT/VERSION"
echo "fetch-rclone: wrote $OUT/rclone ($(/usr/bin/lipo -archs "$OUT/rclone"))"
