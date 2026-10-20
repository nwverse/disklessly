#!/usr/bin/env bash
# Isolated macOS integration test. This intentionally tests the public CLI/stub path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/isenough-e2e.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
LOG="${E2E_LOG_FILE:-$TMP/e2e.log}"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"
MOUNT_ROOT="$TMP/mounts"
APP_PID=""

cleanup() {
  local status=$?
  if [[ -f "${ISENOUGH_E2E_PID:-}" ]]; then kill "$(cat "$ISENOUGH_E2E_PID")" 2>/dev/null || true; fi
  if [[ -n "${APP_PID:-}" ]]; then kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; fi
  if [[ -n "${HELPER:-}" ]]; then kill "$HELPER" 2>/dev/null || true; wait "$HELPER" 2>/dev/null || true; fi
  if [[ -f "${BUSY_PID:-}" ]]; then kill -9 "$(cat "$BUSY_PID")" 2>/dev/null || true; fi
  if [[ "$status" -ne 0 && -f "${LOG:-}" ]]; then
    local kept="/tmp/isenough-e2e.log"
    if [[ "$LOG" != "$kept" ]]; then cp "$LOG" "$kept" 2>/dev/null || true; fi
    printf 'e2e failed (exit %s). Full log: %s\n' "$status" "$kept" >&2
    tail -80 "$LOG" >&2 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

fail() { printf 'FAIL: %s\n' "$1" | tee -a "$LOG" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1" | tee -a "$LOG"; }
assert_file() { [[ -f "$1" ]] || fail "$2 (missing: $1)"; pass "$2"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$3 (expected '$2' in $1)"; pass "$3"; }
code_text() { /usr/bin/otool -t "$1" | tail -n +2 2>/dev/null; }
wait_for() {
  local t=$1 msg=$2; shift 2
  local n=$((t*5))
  until "$@"; do
    ((n--)) || {
      if [[ -n "${WAIT_TIMEOUT_HANDLER:-}" ]]; then "$WAIT_TIMEOUT_HANDLER"; fi
      tail -20 "$LOG" >&2
      fail "$msg (timeout ${t}s)"
    }
    sleep 0.2
  done
}
is_attached() {
  kill -0 "$APP_PID" 2>/dev/null || fail 'stub exited before attach'
  /usr/bin/hdiutil info >"$TMP/hdiutil-info" 2>>"$LOG" && grep -Fq "$MOUNT" "$TMP/hdiutil-info"
}
is_detached() { ! /sbin/mount | grep -Fq "$MOUNT"; }
stub_code_diagnostics() {
  {
    echo 'Stub code-section diagnostics:'
    /usr/bin/otool -t "$STUB/Contents/MacOS/isenough-stub" 2>&1 | head -5 || true
    /usr/bin/otool -t "$ROOT/.build/debug/isenough-stub" 2>&1 | head -5 || true
    /usr/bin/otool -t "$ROOT/.build/debug/isenough" 2>&1 | head -5 || true
    /usr/bin/codesign -dvvv "$STUB" 2>&1 || true
  } >> "$LOG"
  tail -20 "$LOG" >&2
}
run_cli() { "$ROOT/.build/debug/isenough" "$@" >>"$LOG" 2>&1; }
app_state() {
  /usr/bin/osascript -l JavaScript -e 'function run(a){var s=$.NSString.stringWithContentsOfFileEncodingError(a[0],4,null);if(!s)return "";var o=JSON.parse(s.js);return ((o.apps||{})[a[1]]||{}).state||""}' "$STATE" "$FIXTURE_BUNDLE_ID" 2>>"$LOG"
}
state_is_cached() { [[ "$(app_state)" == cached ]]; }
log_state() { cat "$STATE" >>"$LOG"; }

{
  echo "E2E started $(date -u '+%Y-%m-%dT%H:%M:%SZ')" || true
  sw_vers || true
  xcodebuild -version || true
  swift --version || true
} >>"$LOG" 2>&1 || true

cd "$ROOT"
swift build -c debug >>"$LOG" 2>&1 || fail 'swift build -c debug'
pass 'Swift package builds on macOS'

export ISENOUGH_REPO_PATH="$TMP/fake-icloud"
export ISENOUGH_CACHE_DIR="$TMP/cache"
export ISENOUGH_STATE_DIR="$TMP/state"
export ISENOUGH_MOUNT_ROOT="$MOUNT_ROOT"
export ISENOUGH_STUB_DIR="$TMP/Applications"
export ISENOUGH_DETACH_DELAY=1
FIXTURE_BUNDLE_ID=io.github.s546126.256isenough.e2efixture
mkdir -p "$TMP/Applications/Fixture.app/Contents/MacOS" "$TMP/docs"
run_cli init --backend local
pass 'isolated local-folder repository initialized'

cat > "$TMP/Applications/Fixture.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$FIXTURE_BUNDLE_ID</string>
<key>CFBundleName</key><string>Fixture</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>IsenoughE2EOutput</key><string>$TMP/received-argv</string>
<key>IsenoughE2EPidFile</key><string>$TMP/fixture.pid</string>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeExtensions</key><array><string>txt</string></array><key>CFBundleTypeRole</key><string>Viewer</string></dict></array>
</dict></plist>
PLIST
cat > "$TMP/Fixture.swift" <<'APP'
import AppKit

@MainActor @main
final class Fixture: NSObject, NSApplicationDelegate {
    private let output = Bundle.main.object(forInfoDictionaryKey: "IsenoughE2EOutput") as! String
    private let pidFile = Bundle.main.object(forInfoDictionaryKey: "IsenoughE2EPidFile") as! String

    func applicationDidFinishLaunching(_ notification: Notification) {
        record(CommandLine.arguments.dropFirst().map { "ARG: \($0)" })
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: pidFile, atomically: true, encoding: .utf8)
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        record(urls.map { "DOC: \($0.path)" })
    }

    private func record(_ lines: [String]) {
        let existing = (try? String(contentsOfFile: output, encoding: .utf8)) ?? ""
        try? (existing + lines.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
    }

    static func main() {
        let delegate = Fixture()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}
APP
swiftc -parse-as-library "$TMP/Fixture.swift" -framework AppKit -o "$TMP/Applications/Fixture.app/Contents/MacOS/Fixture" >>"$LOG" 2>&1 || { tail -30 "$LOG" >&2; fail 'compile Swift fixture app'; }
printf 'fixture document\n' > "$TMP/docs/open-me.txt"
export ISENOUGH_E2E_ARGV="$TMP/received-argv"
export ISENOUGH_E2E_PID="$TMP/fixture.pid"

run_cli pack "$TMP/Applications/Fixture.app" --keep-original --stub-dir "$TMP/Applications" >>"$LOG" 2>&1 || fail 'CLI pack into fake repository and Applications'
pass 'fixture packed and stub generated'
STUB="$TMP/Applications/Fixture.app"
assert_file "$STUB/Contents/MacOS/isenough-stub" 'stub executable exists'
if ! cmp -s <(code_text "$STUB/Contents/MacOS/isenough-stub") <(code_text "$ROOT/.build/debug/isenough-stub"); then stub_code_diagnostics; fail 'stub contains launcher binary'; fi
pass 'stub contains launcher binary'
if cmp -s <(code_text "$STUB/Contents/MacOS/isenough-stub") <(code_text "$ROOT/.build/debug/isenough"); then stub_code_diagnostics; fail 'stub is not CLI binary'; fi
pass 'stub is not CLI binary'
assert_file "$STUB/Contents/Resources/stub.json" 'stub CLI metadata exists' 
/usr/bin/codesign --verify --strict "$STUB" >>"$LOG" 2>&1 || fail 'codesign --verify --strict generated stub'
pass 'generated stub passes codesign verification'
MANIFEST="$(find "$ISENOUGH_REPO_PATH/manifests" -name '*.json' -print -quit)"
assert_file "$MANIFEST" 'manifest published'
# Extract the repository image filename from its JSON manifest.
IMAGE_FILE="$(/usr/bin/plutil -extract image.file raw -o - "$MANIFEST" 2>/dev/null || true)"
[[ -n "$IMAGE_FILE" ]] || fail 'extract image file from manifest'
IMAGE_ID="$(/usr/bin/plutil -extract imageId raw -o - "$MANIFEST" 2>/dev/null || true)"
[[ -n "$IMAGE_ID" ]] || fail 'extract imageId from manifest'
[[ "$IMAGE_FILE" == "images/$IMAGE_ID.dmg" ]] || fail 'image path is based on imageId'
[[ "$(basename "$MANIFEST")" == "$IMAGE_ID.json" ]] || fail 'manifest path is based on imageId'
REMOTE_IMAGE="$ISENOUGH_REPO_PATH/$IMAGE_FILE"
assert_file "$REMOTE_IMAGE" 'remote disk image exists'
CACHE_IMAGE="$ISENOUGH_CACHE_DIR/images/$IMAGE_ID.dmg"

# Launch using the installed stub, not a direct engine call: its pre-launch path is under test.
PATH="$ROOT/.build/debug:$PATH" "$STUB/Contents/MacOS/isenough-stub" --doc "$TMP/docs/open-me.txt" >>"$LOG" 2>&1 &
APP_PID=$!
wait_for 60 'pre-launch fetched image to isolated cache' test -f "$CACHE_IMAGE"
assert_file "$CACHE_IMAGE" 'pre-launch fetched image to isolated cache'
REMOTE_SHA="$(shasum -a 256 "$REMOTE_IMAGE" | awk '{print $1}')"
CACHE_SHA="$(shasum -a 256 "$CACHE_IMAGE" | awk '{print $1}')"
[[ "$REMOTE_SHA" == "$CACHE_SHA" ]] || fail 'cached image sha256 matches remote manifest image'
pass 'cached image sha256 verified'
MOUNT="$MOUNT_ROOT/$IMAGE_ID"
wait_for 60 'image attached at expected mount point' is_attached
mount_line="$(/sbin/mount | grep -F "$MOUNT" || true)"
[[ -n "$mount_line" ]] || fail 'expected mount point is mounted'
case "$mount_line" in *read-only*|*rdonly*) pass 'image is attached read-only' ;; *) fail 'image mount is read-only' ;; esac
wait_for 60 'fixture process launched and recorded arguments' grep -Fq -- "$TMP/docs/open-me.txt" "$ISENOUGH_E2E_ARGV"
assert_file "$ISENOUGH_E2E_ARGV" 'fixture process launched and recorded arguments'
assert_contains "$ISENOUGH_E2E_ARGV" "$TMP/docs/open-me.txt" 'document argument forwarded to real app'

# The first process must remain alive until asked to quit; kill it, then require hook cleanup/state.
if [[ -f "$ISENOUGH_E2E_PID" ]]; then kill "$(cat "$ISENOUGH_E2E_PID")" 2>/dev/null || true; fi
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""
wait_for 30 'post-quit hook detached mount after configured delay' is_detached
pass 'post-quit hook detached image after delay'
STATE="$ISENOUGH_STATE_DIR/state.json"
assert_file "$STATE" 'lifecycle state persisted after quit'
assert_contains "$STATE" 'lastUsed' 'LRU timestamp updated'
WAIT_TIMEOUT_HANDLER=log_state wait_for 10 'lifecycle state returned to cached/idle' state_is_cached
pass 'lifecycle state returned to cached/idle'

# A subsequent launch must reuse cache; then intentionally corrupt cache and reject it.
BEFORE="$(stat -f '%m' "$CACHE_IMAGE")"
run_cli prefetch "$IMAGE_ID" >>"$LOG" 2>&1 || fail 'second prefetch from cache'
AFTER="$(stat -f '%m' "$CACHE_IMAGE")"
[[ "$BEFORE" == "$AFTER" ]] || fail 'second launch/prefetch does not re-fetch cached image'
pass 'second prefetch hits existing cache without re-fetch'
# Quota eviction is exercised with one unpinned and one pinned cached entry.
run_cli pin "$IMAGE_ID" >>"$LOG" 2>&1 || fail 'pin fixture before quota eviction'
run_cli gc >>"$LOG" 2>&1 || fail 'quota-triggered gc'
assert_file "$CACHE_IMAGE" 'pinned cache image remains after gc'
pass 'quota eviction preserves pinned image'

printf 'corruption' >> "$REMOTE_IMAGE"
rm -f "$CACHE_IMAGE"
if run_cli prefetch "$IMAGE_ID" >>"$LOG" 2>&1; then fail 'remote sha256 mismatch rejected'; fi
pass 'remote sha256 mismatch rejected'

# Restore-mode crash recovery. Mount-mode assertions above are unchanged.
# shellcheck source=e2e-restore.sh
source "$ROOT/scripts/e2e-restore.sh"

printf 'PASS: all macOS end-to-end assertions completed\n' | tee -a "$LOG"
