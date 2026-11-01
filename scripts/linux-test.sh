#!/usr/bin/env bash
# Build and test the Linux CLI in a swift:6.0 container, then smoke-run it.
# Works with Docker or Apple's `container` tool:
#   scripts/linux-test.sh            # build, test, smoke
#   scripts/linux-test.sh build      # build only
#   scripts/linux-test.sh smoke      # build and smoke-run, skip swift test
#   scripts/linux-test.sh shell      # interactive shell with the repo at /src
# The build directory lives in a named volume so it does not clash with macOS's .build.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${DISKLESSLY_LINUX_IMAGE:-swift:6.0}"
MODE="${1:-all}"
if command -v docker >/dev/null 2>&1; then RUNTIME=docker
elif command -v container >/dev/null 2>&1; then RUNTIME=container
else echo "linux-test: need docker or Apple's container tool" >&2; exit 1; fi

INNER='set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# python3 and sqlite3 back test fixtures; curl drives the smoke run.
apt-get update -qq && apt-get install -y -qq libsqlite3-dev g++ python3 sqlite3 curl >/dev/null
# Build from a copy: copying resources straight off a host bind mount trips on
# macOS extended attributes (NSCocoaErrorDomain 512 at "Copying web").
mkdir -p /work && tar -C /src --exclude=./.build --exclude=./build -cf - . | tar -C /work -xf -
cd /work
B="--scratch-path /build"
swift build $B
case "$MODE" in build) exit 0 ;; esac
[ "$MODE" = smoke ] || swift test $B
bash scripts/linux-smoke.sh "$(swift build $B --show-bin-path)/disklessly"'

ARGS=(run --rm --memory 8g --cpus 8 -v "$PWD:/src" -v disklessly-linux-build:/build -e "MODE=$MODE")
if [ "$MODE" = shell ]; then exec "$RUNTIME" "${ARGS[@]}" -it "$IMAGE" bash; fi
exec "$RUNTIME" "${ARGS[@]}" "$IMAGE" bash -c "$INNER"
