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
UI_PID=""

cleanup() {
  local status=$?
  if [[ -f "${ISENOUGH_E2E_PID:-}" ]]; then kill "$(cat "$ISENOUGH_E2E_PID")" 2>/dev/null || true; fi
  if [[ -n "${APP_PID:-}" ]]; then kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; fi
  if [[ -n "${UI_PID:-}" ]]; then kill "$UI_PID" 2>/dev/null || true; wait "$UI_PID" 2>/dev/null || true; fi
  if [[ -n "${HELPER:-}" ]]; then kill "$HELPER" 2>/dev/null || true; wait "$HELPER" 2>/dev/null || true; fi
  if [[ -f "${BUSY_PID:-}" ]]; then kill -9 "$(cat "$BUSY_PID")" 2>/dev/null || true; fi
  if [[ "$status" -ne 0 && -f "${LOG:-}" ]]; then
    local kept="/tmp/isenough-e2e.log"
    if [[ "$LOG" != "$kept" ]]; then cp "$LOG" "$kept" 2>/dev/null || true; fi
    printf 'e2e failed (exit %s). Full log: %s\n' "$status" "$kept" >&2
    tail -80 "$LOG" >&2 || true
  fi
  force_detach_isenough_mounts
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

fail() {
  if isenough_mounts_present; then
    list_image_mounts >>"$LOG" 2>&1 || true
    printf 'FAIL: %s (isenough mount still attached under %s)\n' "$1" "${MOUNT_ROOT:-$TMP}" | tee -a "$LOG" >&2
  else
    printf 'FAIL: %s\n' "$1" | tee -a "$LOG" >&2
  fi
  exit 1
}
# Exit 0 means `diskutil image` exists. The help text is not read.
diskutil_image_available() {
  /usr/sbin/diskutil image --help >/dev/null 2>&1
}
alt_mount_path() {
  case "$1" in
    /private/*) printf '/%s\n' "${1#/private/}" ;;
    /var/*|/tmp/*|/etc/*) printf '/private%s\n' "$1" ;;
    *) printf '\n' ;;
  esac
}
# Forced detach. diskutil has no image detach: eject force, then unmount force.
# hdiutil detach -force still runs so an older attachment is not left behind.
detach_one_mount() {
  local mp="$1" alt
  if diskutil_image_available; then
    /usr/sbin/diskutil eject force "$mp" >>"${LOG:-/dev/null}" 2>&1 || /usr/sbin/diskutil unmount force "$mp" >>"${LOG:-/dev/null}" 2>&1 || true
  fi
  /usr/bin/hdiutil detach -force "$mp" >>"${LOG:-/dev/null}" 2>&1 || true
  alt="$(alt_mount_path "$mp")"
  [[ -n "$alt" ]] || return 0
  if diskutil_image_available; then
    /usr/sbin/diskutil eject force "$alt" >>"${LOG:-/dev/null}" 2>&1 || /usr/sbin/diskutil unmount force "$alt" >>"${LOG:-/dev/null}" 2>&1 || true
  fi
  /usr/bin/hdiutil detach -force "$alt" >>"${LOG:-/dev/null}" 2>&1 || true
}
# Print mount-point values from a plist. Keys are machine names, not sentences.
plist_mount_points() {
  /usr/bin/python3 - "$1" <<'PY'
import plistlib, sys
def walk(value, found):
    if isinstance(value, dict):
        for key, item in value.items():
            if key in ("mount-point", "MountPoint") and isinstance(item, str):
                found.append(item)
            else:
                walk(item, found)
    elif isinstance(value, list):
        for item in value:
            walk(item, found)
with open(sys.argv[1], "rb") as handle:
    data = plistlib.load(handle)
found = []
walk(data, found)
print("\n".join(found))
PY
}
hdiutil_mount_points() {
  local plist="${TMP:-/tmp}/hdiutil-info.plist"
  /usr/bin/hdiutil info -plist >"$plist" 2>/dev/null || return 0
  plist_mount_points "$plist" 2>/dev/null || true
}
mount_point_is_attached() {
  local mp="$1" alt points
  if diskutil_image_available; then
    /usr/sbin/diskutil info -plist "$mp" >/dev/null 2>&1 && return 0
    alt="$(alt_mount_path "$mp")"
    [[ -n "$alt" ]] && /usr/sbin/diskutil info -plist "$alt" >/dev/null 2>&1 && return 0
    return 1
  fi
  points="$(hdiutil_mount_points)"
  printf '%s\n' "$points" | grep -Fx "$mp" >/dev/null && return 0
  alt="$(alt_mount_path "$mp")"
  [[ -n "$alt" ]] && printf '%s\n' "$points" | grep -Fx "$alt" >/dev/null
}
force_detach_isenough_mounts() {
  local token mp point
  token="$(basename "${TMP:-}")"
  [[ -n "$token" ]] || return 0
  if [[ -d "${MOUNT_ROOT:-}" ]]; then
    for mp in "$MOUNT_ROOT"/*; do
      [[ -e "$mp" ]] || continue
      detach_one_mount "$mp"
    done
  fi
  while IFS= read -r point; do
    [[ "$point" == *"$token"* ]] || continue
    detach_one_mount "$point"
  done < <(hdiutil_mount_points)
}
isenough_mounts_present() {
  local token mp point
  token="$(basename "${TMP:-}")"
  [[ -n "$token" ]] || return 1
  if [[ -d "${MOUNT_ROOT:-}" ]]; then
    for mp in "$MOUNT_ROOT"/*; do
      [[ -e "$mp" ]] || continue
      if mount_point_is_attached "$mp"; then return 0; fi
    done
  fi
  while IFS= read -r point; do
    [[ "$point" == *"$token"* ]] && return 0
  done < <(hdiutil_mount_points)
  return 1
}
list_image_mounts() {
  if diskutil_image_available; then
    /usr/sbin/diskutil list || true
  fi
  /usr/bin/hdiutil info -plist || true
}
assert_no_isenough_mounts() {
  if isenough_mounts_present; then
    list_image_mounts >>"$LOG" 2>&1 || true
    fail "no isenough mount should remain ($1)"
  fi
  pass "no isenough mount left behind ($1)"
}
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
  mount_point_is_attached "$MOUNT"
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
mkdir -p "$TMP/Applications/Fixture.app/Contents/MacOS" "$TMP/Applications/Fixture.app/Contents/Resources" "$TMP/docs"
printf 'icns' > "$TMP/Applications/Fixture.app/Contents/Resources/AppIcon.icns"
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
<key>CFBundleIconFile</key><string>AppIcon</string>
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
assert_file "$STUB/Contents/Resources/AppIcon.icns" 'stub icon copied from the original app'
ICON_KEY="$(/usr/bin/plutil -extract CFBundleIconFile raw -o - "$STUB/Contents/Info.plist" 2>/dev/null || true)"
[[ "$ICON_KEY" == "AppIcon" ]] || fail "stub Info.plist CFBundleIconFile is '$ICON_KEY'"
pass 'stub Info.plist names the copied icon' 
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

# Session tiering against a temp HOME. The alias spelling (/var vs /private/var)
# must round-trip through the index.
SESSION_HOME="$TMP/session-home"
mkdir -p "$SESSION_HOME/.pi/agent/sessions"
SESSION_OLD="$SESSION_HOME/.pi/agent/sessions/old.jsonl"
SESSION_FRESH="$SESSION_HOME/.pi/agent/sessions/fresh.jsonl"
printf '%s\n' '{"type":"user","text":"pack the blender notes"}' > "$SESSION_OLD"
printf '%s\n' 'still hot' > "$SESSION_FRESH"
touch -t "$(date -v-30d '+%Y%m%d%H%M.%S')" "$SESSION_OLD"
touch -t "$(date -v-2H '+%Y%m%d%H%M.%S')" "$SESSION_FRESH"
SESSION_CANON="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SESSION_OLD")"
case "$SESSION_HOME" in
  /private/*) SESSION_HOME_ALIAS="/${SESSION_HOME#/private/}" ;;
  *) SESSION_HOME_ALIAS="$SESSION_HOME" ;;
esac
SESSION_ALIAS="$SESSION_HOME_ALIAS/.pi/agent/sessions/old.jsonl"
HOME="$SESSION_HOME_ALIAS" "$ROOT/.build/debug/isenough" --json sessions >"$TMP/sessions-dry.json" 2>>"$LOG" || fail 'sessions dry run'
# Refuse --apply unless every dry-run path stays inside the temp home. An empty
# cold list is not enough: a scan of the real home shows up in skipped.
if ! /usr/bin/python3 - "$TMP/sessions-dry.json" "$SESSION_HOME" "$SESSION_CANON" >>"$LOG" 2>&1 <<'PY'
import json, os, sys
report = json.load(open(sys.argv[1]))
root = os.path.realpath(sys.argv[2])
canon = os.path.realpath(sys.argv[3])
paths = list(report.get("cold") or [])
for item in report.get("skipped") or []:
    paths.append(item["path"])
bad = []
for path in paths:
    real = os.path.realpath(path)
    if real != root and not real.startswith(root + os.sep):
        bad.append(path)
if bad:
    print("outside temp home:")
    print("\n".join(bad[:30]))
    raise SystemExit(1)
if report.get("applied") is not False or report.get("cold") != [canon]:
    print("dry run cold %s expected %s" % (report.get("cold"), [canon]))
    raise SystemExit(1)
PY
then
  fail 'sessions dry run listed a path outside the temp home; refusing to apply'
fi
[[ -f "$SESSION_CANON" ]] || fail 'sessions dry run deleted a file'
pass 'sessions dry run keeps the cold file and reports its canonical path'
HOME="$SESSION_HOME_ALIAS" "$ROOT/.build/debug/isenough" --json sessions --apply >"$TMP/sessions-apply.json" 2>>"$LOG" || fail 'sessions apply'
/usr/bin/python3 - "$TMP/sessions-apply.json" "$SESSION_CANON" "$ISENOUGH_STATE_DIR/sessions/index.sqlite" <<'PY' || fail 'sessions apply canonical index'
import json, sqlite3, sys
report, canon, db_path = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
paths = [row[0] for row in sqlite3.connect(db_path).execute("SELECT path FROM entries")]
segments = report.get("segments") or []
if report.get("applied") is not True or report.get("cold") != [canon] or paths != [canon]:
    raise SystemExit(f"apply {report} index {paths} expected {[canon]}")
if not segments or any(item.startswith("sessions/pi/") for item in segments):
    raise SystemExit(f"segment paths {segments}")
PY
[[ ! -f "$SESSION_CANON" ]] || fail 'sessions apply left the cold file in place'
[[ -f "$SESSION_FRESH" ]] || fail 'sessions apply removed a hot file'
pass 'sessions apply packs the cold file and keeps the hot file'
HOME="$SESSION_HOME_ALIAS" "$ROOT/.build/debug/isenough" --json sessions search blender >"$TMP/sessions-search.json" 2>>"$LOG" || fail 'sessions search'
/usr/bin/python3 - "$TMP/sessions-search.json" "$SESSION_CANON" <<'PY' || fail 'sessions search missed the packed preview'
import json, sys
hits, canon = json.load(open(sys.argv[1])), sys.argv[2]
if len(hits) != 1 or hits[0].get("path") != canon or "blender" not in hits[0].get("preview", ""):
    raise SystemExit(f"search {hits}")
PY
pass 'sessions search finds the packed preview'
HOME="$SESSION_HOME_ALIAS" "$ROOT/.build/debug/isenough" --json sessions restore "$SESSION_ALIAS" >"$TMP/sessions-restore.json" 2>>"$LOG" || fail 'sessions restore'
/usr/bin/python3 - "$TMP/sessions-restore.json" "$SESSION_CANON" <<'PY' || fail 'sessions restore path'
import json, sys
report, canon = json.load(open(sys.argv[1])), sys.argv[2]
if report.get("ok") is not True or report.get("path") != canon:
    raise SystemExit(f"restore {report} expected {canon}")
PY
grep -Fq 'pack the blender notes' "$SESSION_CANON" || fail 'sessions restore bytes'
pass 'sessions restore round-trip writes the canonical path'

# Loopback UI: 127.0.0.1 only, token required, clean SIGTERM exit.
"$ROOT/.build/debug/isenough" ui >"$TMP/ui-server.log" 2>&1 &
UI_PID=$!
UI_URL=""
for _ in $(seq 1 50); do
  if ! kill -0 "$UI_PID" 2>/dev/null; then fail 'isenough ui exited before printing a URL'; fi
  UI_URL="$(grep -Eo 'http://127\.0\.0\.1:[0-9]+/\?token=[^[:space:]]+' "$TMP/ui-server.log" | head -n 1 || true)"
  [[ -n "$UI_URL" ]] && break
  sleep 0.1
done
[[ -n "$UI_URL" ]] || fail 'isenough ui did not print a loopback URL'
/usr/sbin/lsof -nP -a -p "$UI_PID" -iTCP -sTCP:LISTEN >"$TMP/ui-listen.txt" 2>>"$LOG" || fail 'lsof UI listen socket'
grep -F '127.0.0.1:' "$TMP/ui-listen.txt" >/dev/null || fail 'isenough ui is not bound to 127.0.0.1'
if grep -E '(\*:|0\.0\.0\.0:)' "$TMP/ui-listen.txt" >/dev/null; then fail 'isenough ui listened outside loopback'; fi
UI_PORT="$(printf '%s' "$UI_URL" | sed -E 's#http://127\.0\.0\.1:([0-9]+)/.*#\1#')"
UI_DENIED="$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${UI_PORT}/api/status")"
[[ "$UI_DENIED" == "401" ]] || fail "isenough ui without a token returned $UI_DENIED"
UI_PAGE="$(/usr/bin/curl -s -o "$TMP/ui-page.html" -w '%{http_code}' "$UI_URL")"
[[ "$UI_PAGE" == "200" ]] || fail "isenough ui with a token returned $UI_PAGE"
grep -Fq 'app.js?token=' "$TMP/ui-page.html" || fail 'isenough ui page omitted the token'
kill -TERM "$UI_PID"
set +e
wait "$UI_PID"
UI_STATUS=$?
set -e
UI_PID=""
[[ "$UI_STATUS" -eq 0 ]] || fail "isenough ui exit status $UI_STATUS"
pass 'isenough ui serves loopback with a token and exits cleanly'

# P0-1: a second state directory must not replace the app when the shared image is gone.
P0_SRC="$TMP/Applications/Fixture.256orig.app"
[[ -d "$P0_SRC" ]] || fail 'kept original missing for second-Mac pack'
mkdir -p "$TMP/p0"
cp -R "$P0_SRC" "$TMP/p0/Fixture.app"
rm -f "$REMOTE_IMAGE"
set +e
ISENOUGH_STATE_DIR="$TMP/state-b" ISENOUGH_CACHE_DIR="$TMP/cache-b" ISENOUGH_STUB_DIR="$TMP/stubs-b" \
  "$ROOT/.build/debug/isenough" pack "$TMP/p0/Fixture.app" --mode mount >>"$LOG" 2>&1
P0_CODE=$?
set -e
[[ "$P0_CODE" -eq 5 ]] || fail "second Mac pack exited $P0_CODE, expected 5"
P0_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$TMP/p0/Fixture.app/Contents/Info.plist" 2>/dev/null || true)"
[[ "$P0_ID" == "$FIXTURE_BUNDLE_ID" ]] || fail "second Mac pack changed the original ($P0_ID)"
pass 'second Mac pack refuses a missing image and leaves the original'

# Two homes, one repo, one month. Each Mac restores its own session.
plant_cold_session() {
  local home="$1" body="$2" file
  mkdir -p "$home/.pi/agent/sessions"
  file="$home/.pi/agent/sessions/cold.jsonl"
  printf '%s\n' "$body" > "$file"
  touch -t "$(date -v-30d '+%Y%m%d%H%M.%S')" "$file"
  printf '%s\n' "$file"
}
SESS_A="$(plant_cold_session "$TMP/home-a" 'machine-a-session')"
SESS_B="$(plant_cold_session "$TMP/home-b" 'machine-b-session')"
HOME="$TMP/home-a" ISENOUGH_STATE_DIR="$TMP/state-sess-a" "$ROOT/.build/debug/isenough" --json sessions --apply >"$TMP/sess-a.json" 2>>"$LOG" || fail 'machine A sessions apply'
HOME="$TMP/home-b" ISENOUGH_STATE_DIR="$TMP/state-sess-b" "$ROOT/.build/debug/isenough" --json sessions --apply >"$TMP/sess-b.json" 2>>"$LOG" || fail 'machine B sessions apply'
rm -f "$SESS_A" "$SESS_B"
HOME="$TMP/home-a" ISENOUGH_STATE_DIR="$TMP/state-sess-a" "$ROOT/.build/debug/isenough" --json sessions restore "$SESS_A" >"$TMP/sess-a-restore.json" 2>>"$LOG" || fail 'machine A sessions restore'
HOME="$TMP/home-b" ISENOUGH_STATE_DIR="$TMP/state-sess-b" "$ROOT/.build/debug/isenough" --json sessions restore "$SESS_B" >"$TMP/sess-b-restore.json" 2>>"$LOG" || fail 'machine B sessions restore'
grep -Fq 'machine-a-session' "$SESS_A" || fail 'machine A restore bytes'
grep -Fq 'machine-b-session' "$SESS_B" || fail 'machine B restore bytes'
pass 'two homes archive and restore in the same month'

run_cli evict-local >>"$LOG" 2>&1 || fail 'evict-local on the local repo'
pass 'evict-local completes on the local repo'
run_cli cleanup-backups >>"$LOG" 2>&1 || fail 'cleanup-backups on the local repo'
pass 'cleanup-backups completes on the local repo'

# Mount-mode fixture: one attach across two launches, then unpack back to a signed app.
UNPACK_ID="io.github.s546126.256isenough.e2eunpack"
mkdir -p "$TMP/unpack-apps/Unpack.app/Contents/MacOS" "$TMP/unpack-docs"
cat > "$TMP/UnpackInfo.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$UNPACK_ID</string>
<key>CFBundleName</key><string>Unpack</string>
<key>CFBundleExecutable</key><string>Unpack</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>IsenoughE2EOutput</key><string>$TMP/unpack-argv</string>
<key>IsenoughE2EPidFile</key><string>$TMP/unpack.pid</string>
</dict></plist>
PLIST
cp "$TMP/UnpackInfo.plist" "$TMP/unpack-apps/Unpack.app/Contents/Info.plist"
swiftc -parse-as-library "$TMP/Fixture.swift" -framework AppKit -o "$TMP/unpack-apps/Unpack.app/Contents/MacOS/Unpack" >>"$LOG" 2>&1 || fail 'compile unpack fixture'
/usr/bin/codesign --force --sign - "$TMP/unpack-apps/Unpack.app" >>"$LOG" 2>&1 || fail 'sign unpack fixture'
ISENOUGH_STATE_DIR="$TMP/state" ISENOUGH_STUB_DIR="$TMP/unpack-apps" \
  "$ROOT/.build/debug/isenough" pack "$TMP/unpack-apps/Unpack.app" --mode mount --stub-dir "$TMP/unpack-apps" >>"$LOG" 2>&1 || fail 'pack unpack fixture'
UNPACK_STUB="$TMP/unpack-apps/Unpack.app"
UNPACK_IMAGE="$(/usr/bin/python3 - "$UNPACK_STUB/Contents/Resources/stub.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["imageId"])
PY
)"
ISENOUGH_STATE_DIR="$TMP/state" "$ROOT/.build/debug/isenough" launch "$UNPACK_ID" --no-wait >>"$LOG" 2>&1 || fail 'first unpack-fixture launch'
UNPACK_MOUNT="$MOUNT_ROOT/$UNPACK_IMAGE"
wait_for 60 'unpack fixture attached' mount_point_is_attached "$UNPACK_MOUNT"
printf 'second document\n' > "$TMP/unpack-docs/note.txt"
ISENOUGH_STATE_DIR="$TMP/state" "$ROOT/.build/debug/isenough" launch "$UNPACK_ID" --doc "$TMP/unpack-docs/note.txt" --no-wait >>"$LOG" 2>&1 || fail 'second launch while the first is still up'
MOUNT_COUNT="$(hdiutil_mount_points | sed 's#^/private##' | grep -F "$UNPACK_IMAGE" | sort -u | wc -l | tr -d ' ')"
[[ "$MOUNT_COUNT" == "1" ]] || fail "expected one hdiutil mount for the unpack fixture, saw $MOUNT_COUNT"
pass 'second launch reuses the existing disk image mount'
if [[ -f "$TMP/unpack.pid" ]]; then kill "$(cat "$TMP/unpack.pid")" 2>/dev/null || true; fi
unpack_detached() { ! mount_point_is_attached "$UNPACK_MOUNT"; }
wait_for 30 'unpack fixture detached' unpack_detached
ISENOUGH_STATE_DIR="$TMP/state" "$ROOT/.build/debug/isenough" unpack "$UNPACK_STUB" >>"$LOG" 2>&1 || fail 'unpack mount fixture'
UNPACK_DEST_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$UNPACK_STUB/Contents/Info.plist" 2>/dev/null || true)"
[[ "$UNPACK_DEST_ID" == "$UNPACK_ID" ]] || fail "unpack left bundle id $UNPACK_DEST_ID"
/usr/bin/codesign --verify "$UNPACK_STUB" >>"$LOG" 2>&1 || fail 'codesign --verify unpacked app'
pass 'unpack restores a signed app'

# A running fixture must refuse pack.
RUN_ID="io.github.s546126.256isenough.e2erunning"
mkdir -p "$TMP/running/Running.app/Contents/MacOS"
cat > "$TMP/running/Running.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$RUN_ID</string>
<key>CFBundleName</key><string>Running</string>
<key>CFBundleExecutable</key><string>Running</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>IsenoughE2EOutput</key><string>$TMP/running-argv</string>
<key>IsenoughE2EPidFile</key><string>$TMP/running.pid</string>
</dict></plist>
PLIST
swiftc -parse-as-library "$TMP/Fixture.swift" -framework AppKit -o "$TMP/running/Running.app/Contents/MacOS/Running" >>"$LOG" 2>&1 || fail 'compile running fixture'
"$TMP/running/Running.app/Contents/MacOS/Running" >>"$LOG" 2>&1 &
RUN_PID=$!
sleep 0.5
set +e
ISENOUGH_STATE_DIR="$TMP/state" "$ROOT/.build/debug/isenough" pack "$TMP/running/Running.app" --mode mount --stub-dir "$TMP/running-stubs" >>"$LOG" 2>&1
RUN_CODE=$?
set -e
kill "$RUN_PID" 2>/dev/null || true
wait "$RUN_PID" 2>/dev/null || true
[[ "$RUN_CODE" -eq 9 ]] || fail "pack of a running app exited $RUN_CODE, expected 9"
[[ -d "$TMP/running/Running.app" ]] || fail 'pack of a running app removed it'
pass 'pack of a running app exits 9'

printf 'PASS: all macOS end-to-end assertions completed\n' | tee -a "$LOG"
