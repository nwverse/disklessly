#!/usr/bin/env bash
# Build the Linux CLI tarball in a container (Docker or Apple's `container`).
#
#   scripts/release-linux.sh                      # this machine's architecture
#   DISKLESSLY_LINUX_ARCH=amd64 scripts/release-linux.sh   # x86_64 (emulated on Apple silicon; slow)
#
# Environment:
#   DISKLESSLY_LINUX_IMAGE  build image, default swift:6.0-rhel-ubi9. Its glibc 2.34 is the
#                           floor, so the binary runs on RHEL/Oracle/Rocky 9, Debian 12,
#                           Ubuntu 22.04, and newer.
#   DISKLESSLY_LINUX_ARCH   amd64 or arm64, default the host's.
#   DISKLESSLY_DIST_DIR     output folder, default <repo>/dist
#   DISKLESSLY_VERSION      passed to gen-version.sh
#
# Output in DISKLESSLY_DIST_DIR:
#   disklessly-<ver>-linux-<x86_64|aarch64>.tar.gz   bin/disklessly, share/disklessly/web, docs
#   SHA256SUMS (appended)
#
# The Swift runtime and Foundation are linked statically. At run time the binary needs
# glibc, libsqlite3, libcurl, and libxml2 (FoundationNetworking/FoundationXML), which
# server and desktop installs ship; slim container images may need them installed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${DISKLESSLY_DIST_DIR:-$ROOT/dist}"
IMAGE="${DISKLESSLY_LINUX_IMAGE:-swift:6.0-rhel-ubi9}"
case "${DISKLESSLY_LINUX_ARCH:-$(uname -m)}" in
  amd64|x86_64) ARCH=amd64; TRIPLE=x86_64 ;;
  arm64|aarch64) ARCH=arm64; TRIPLE=aarch64 ;;
  *) echo "release-linux: unknown arch ${DISKLESSLY_LINUX_ARCH:-}" >&2; exit 64 ;;
esac
if command -v docker >/dev/null 2>&1; then RUNTIME=docker
elif command -v container >/dev/null 2>&1; then RUNTIME=container
else echo "release-linux: need docker or Apple's container tool" >&2; exit 1; fi
log() { printf 'release-linux: %s\n' "$*"; }

# Stamp the version on a copy so the checkout stays clean.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -C "$ROOT" --exclude=./.build --exclude=./build --exclude=./dist -cf - . | tar -C "$WORK" -xf -
VERSION_FILE=Sources/DisklesslyEngine/EngineInstall.swift
cp "$ROOT/$VERSION_FILE" "$WORK/version.orig"
bash "$ROOT/scripts/gen-version.sh" >/dev/null
cp "$ROOT/$VERSION_FILE" "$WORK/$VERSION_FILE"
cp "$WORK/version.orig" "$ROOT/$VERSION_FILE" && rm "$WORK/version.orig"
VERSION="$(sed -n 's/^    public static let version = "\(.*\)"$/\1/p' "$WORK/$VERSION_FILE" | head -n 1)"
NAME="disklessly-$VERSION-linux-$TRIPLE"
log "building $NAME in $IMAGE"

INNER='set -euo pipefail
if command -v dnf >/dev/null 2>&1; then dnf install -y -q sqlite-devel >/dev/null
elif command -v microdnf >/dev/null 2>&1; then microdnf install -y sqlite-devel >/dev/null
else apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libsqlite3-dev >/dev/null; fi
mkdir -p /work && tar -C /src -cf - . | tar -C /work -xf -
cd /work
swift build -c release --static-swift-stdlib --product disklessly
BIN="$(swift build -c release --show-bin-path)"
OUT="/out/$NAME"
rm -rf "$OUT" && mkdir -p "$OUT/bin" "$OUT/share/disklessly" "$OUT/share/doc/disklessly"
cp "$BIN/disklessly" "$OUT/bin/disklessly"
strip "$OUT/bin/disklessly" 2>/dev/null || true
cp -R Sources/disklessly/web "$OUT/share/disklessly/web"
cp LICENSE THIRD_PARTY_NOTICES.md PRIVACY.md docs/linux.md "$OUT/share/doc/disklessly/"
"$OUT/bin/disklessly" version
tar -C /out -czf "/out/$NAME.tar.gz" "$NAME"
rm -rf "$OUT"'

mkdir -p "$DIST"
"$RUNTIME" run --rm --platform "linux/$ARCH" --memory 8g --cpus 8 \
  -v "$WORK:/src" -v "$DIST:/out" -e "NAME=$NAME" "$IMAGE" bash -c "$INNER"
( cd "$DIST" && grep -v " $NAME.tar.gz\$" SHA256SUMS 2>/dev/null > SHA256SUMS.new || true
  shasum -a 256 "$NAME.tar.gz" >> SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS )
log "wrote $DIST/$NAME.tar.gz"
