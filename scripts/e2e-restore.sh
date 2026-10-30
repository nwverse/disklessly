# Sourced by scripts/e2e.sh after the mount-mode assertions. Uses the same
# TMP, LOG, run_cli, wait_for, and fail/pass helpers. Safe to run as part of
# `bash scripts/e2e.sh` on a Mac; it is not a standalone entry point.
#
# Local command, from the repository root, with Xcode's swift on PATH:
#   bash scripts/e2e.sh

command -v python3 >/dev/null || fail 'python3 is required for restore e2e JSON edits'
export ISENOUGH_PROBE_INTERVAL=0
export ISENOUGH_DETACH_DELAY=0

config_path() { printf '%s/config.json' "$ISENOUGH_STATE_DIR"; }

set_faults() {
  local point="$1"
  python3 - "$point" "$(config_path)" <<'PY'
import json, sys
point, path = sys.argv[1], sys.argv[2]
with open(path) as fh:
    config = json.load(fh)
if point:
    config["faults"] = [point]
    config["faultMode"] = "kill"
else:
    config.pop("faults", None)
    config.pop("faultMode", None)
with open(path, "w") as fh:
    json.dump(config, fh)
PY
}

bundle_id_of() {
  /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

journal_field() {
  local app="$1" field="$2"
  python3 - "$ISENOUGH_STATE_DIR" "$app" "$field" <<'PY'
import json, os, sys
state, app, field = sys.argv[1:]
directory = os.path.join(state, "journals")
if not os.path.isdir(directory):
    sys.exit(1)
found = None
for name in sorted(os.listdir(directory)):
    if not name.endswith(".json"):
        continue
    with open(os.path.join(directory, name)) as fh:
        journal = json.load(fh)
    if journal.get("appId") == app:
        found = journal
if found is None or field not in found:
    sys.exit(1)
value = found[field]
print(value if not isinstance(value, (dict, list)) else json.dumps(value))
PY
}

adopt_count() {
  local app="$1"
  python3 - "$ISENOUGH_STATE_DIR/events.jsonl" "$app" <<'PY'
import json, os, sys
path, app = sys.argv[1:]
count = 0
if os.path.exists(path):
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            event = json.loads(line)
            if event.get("event") == "adopt" and event.get("appId") == app:
                count += 1
print(count)
PY
}

app_record() {
  python3 - "$STATE" "$1" <<'PY'
import json, sys
state, app = sys.argv[1:]
with open(state) as fh:
    data = json.load(fh)
print(json.dumps((data.get("apps") or {}).get(app) or {}))
PY
}

assert_stub_terminal() {
  local label="$1" app="$2" bid="$3"
  local id journals
  id="$(bundle_id_of "$app")"
  [[ "$id" == "$bid.256stub" ]] || fail "$label: destination bundle id is '$id', expected stub"
  journals="$(find "$ISENOUGH_STATE_DIR/journals" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$journals" == "0" ]] || fail "$label: $journals journal(s) still open"
  if [[ -d "$TMP/Applications/.256isenough-staging" ]]; then
    local left
    left="$(find "$TMP/Applications/.256isenough-staging" -mindepth 1 -print)"
    [[ -z "$left" ]] || fail "$label: staging leftovers: $left"
  fi
}

# Phases after the hand-off are driven by the detached `hook watch`. When the
# fault kills that watcher, the waiting `launch` adopts the journal and may
# finish cleanly (exit 0); an adopt event proves the watcher was killed.
# Usage: expect_kill POINT IMAGE_ID BUNDLE_ID
expect_kill() {
  local point="$1" adopts_before adopts_after
  adopts_before="$(adopt_count "$3")"
  set +e
  run_cli launch "$2"
  local status=$?
  set -e
  [[ "$status" -eq 137 || "$status" -eq 9 ]] && return 0
  adopts_after="$(adopt_count "$3")"
  [[ "$status" -eq 0 && "${adopts_after:-0}" -gt "${adopts_before:-0}" ]] && return 0
  # After closed:afterMutation the journal is already gone, so there is nothing
  # left to adopt; recover_point still checks the terminal state.
  [[ "$status" -eq 0 && "$point" == "closed:afterMutation" ]] && return 0
  fail "expected SIGKILL at $point, exit $status (see $LOG)"
}

recover_point() {
  local point="$1" app="$2" bid="$3"
  set_faults ""
  run_cli gc || fail "gc after $point"
  run_cli gc || fail "second gc after $point"
  assert_stub_terminal "$point" "$app" "$bid"
  local before after
  before="$(cat "$STATE")"
  run_cli gc || fail "third gc after $point"
  after="$(cat "$STATE")"
  [[ "$before" == "$after" ]] || fail "third gc rewrote state after $point"
}

write_restore_source() {
  cat > "$TMP/RestoreApp.swift" <<'APP'
import AppKit

@MainActor @main
final class RestoreApp: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if "ISENOUGH_FIXTURE_BUILD".isEmpty { NSApp.terminate(nil) }
        let hold = Bundle.main.object(forInfoDictionaryKey: "IsenoughHoldFile") as? String ?? ""
        let pidFile = Bundle.main.object(forInfoDictionaryKey: "IsenoughE2EPidFile") as? String ?? ""
        if !pidFile.isEmpty {
            try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: pidFile, atomically: true, encoding: .utf8)
        }
        if !hold.isEmpty && FileManager.default.fileExists(atPath: hold) {
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
                if !FileManager.default.fileExists(atPath: hold) {
                    timer.invalidate()
                    NSApp.terminate(nil)
                }
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = RestoreApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
APP
  compile_restore_bin v1 "$TMP/restore-bin"
}

compile_restore_bin() {
  local tag="$1" out="$2"
  sed "s/ISENOUGH_FIXTURE_BUILD/isenough-fixture-${tag}/" "$TMP/RestoreApp.swift" > "$TMP/RestoreApp.${tag}.swift"
  swiftc -parse-as-library "$TMP/RestoreApp.${tag}.swift" -framework AppKit -o "$out" >>"$LOG" 2>&1 || fail "compile restore fixture ${tag}"
}

cdhash_of() {
  /usr/bin/codesign -dvvv "$1" 2>&1 | awk -F= '/^CDHash=/{print tolower($2); exit}'
}

make_app() {
  local dest="$1" bid="$2" name="$3" hold="$4" pidfile="$5" marker="$6"
  mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"
  cp "$TMP/restore-bin" "$dest/Contents/MacOS/Restore"
  chmod 755 "$dest/Contents/MacOS/Restore"
  printf '%s\n' "$marker" > "$dest/Contents/Resources/marker.txt"
  cat > "$dest/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bid</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleExecutable</key><string>Restore</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
<key>IsenoughHoldFile</key><string>$hold</string>
<key>IsenoughE2EPidFile</key><string>$pidfile</string>
</dict></plist>
PLIST
  /usr/bin/codesign --force --sign - "$dest" >>"$LOG" 2>&1 || fail "codesign $dest"
}

image_id_for() {
  python3 - "$ISENOUGH_REPO_PATH" "$1" <<'PY'
import json, glob, os, sys
repo, bundle = sys.argv[1:]
for path in glob.glob(os.path.join(repo, "manifests", "*.json")):
    with open(path) as fh:
        manifest = json.load(fh)
    if manifest.get("bundleId") == bundle:
        print(manifest["imageId"])
        break
PY
}

# --- A30: a Mac App Store receipt selects restore mode ---
MAS_BUNDLE=io.github.s546126.256isenough.e2emas
MAS_APP="$TMP/Applications/Mas.app"
write_restore_source
make_app "$MAS_APP" "$MAS_BUNDLE" "Mas" "" "" "mas"
mkdir -p "$MAS_APP/Contents/_MASReceipt"
printf 'receipt\n' > "$MAS_APP/Contents/_MASReceipt/receipt"
/usr/bin/codesign --force --sign - "$MAS_APP" >>"$LOG" 2>&1 || fail 're-sign MAS fixture after receipt'
run_cli pack "$MAS_APP" --keep-original --stub-dir "$TMP/Applications" || fail 'pack MAS receipt app without --mode'
MAS_MODE="$(python3 - "$ISENOUGH_REPO_PATH" "$MAS_BUNDLE" <<'PY'
import json, glob, os, sys
repo, bundle = sys.argv[1:]
for path in glob.glob(os.path.join(repo, "manifests", "*.json")):
    with open(path) as fh:
        manifest = json.load(fh)
    if manifest.get("bundleId") == bundle:
        print(manifest.get("mode", ""))
        break
PY
)"
[[ "$MAS_MODE" == "restore" ]] || fail "MAS receipt did not select restore mode (got ${MAS_MODE:-empty})"
pass 'MAS receipt selects restore mode'

# --- fast restore app: happy path, per-phase kill, stub regeneration ---
RESTORE_BUNDLE=io.github.s546126.256isenough.e2erestore
RESTORE_APP="$TMP/Applications/Restore.app"
make_app "$RESTORE_APP" "$RESTORE_BUNDLE" "Restore" "" "" "v1"
run_cli pack "$RESTORE_APP" --mode restore --keep-original --stub-dir "$TMP/Applications" || fail 'pack restore fixture'
RESTORE_ID="$(image_id_for "$RESTORE_BUNDLE")"
[[ -n "$RESTORE_ID" ]] || fail 'restore image id missing'
pass 'restore fixture packed'

PATH="$ROOT/.build/debug:$PATH" "$RESTORE_APP/Contents/MacOS/isenough-stub" >>"$LOG" 2>&1 || fail 'A31 stub launch of restore app'
assert_stub_terminal 'A31' "$RESTORE_APP" "$RESTORE_BUNDLE"
RESTORE_OUTCOME="$(python3 - "$STATE" "$RESTORE_BUNDLE" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    apps = json.load(fh).get("apps") or {}
print(((apps.get(sys.argv[2]) or {}).get("lastOutcome") or {}).get("name", ""))
PY
)"
[[ "$RESTORE_OUTCOME" == "restoredOut" ]] || fail "A31 lastOutcome is '$RESTORE_OUTCOME'"
pass 'A31 restore launch returns the stub and records restoredOut'
assert_no_isenough_mounts 'after A31'

PHASES=(prepared extracted stubParked installed active quiesced inspected appMoved stubBack disposed retired closed)
EDGES=(beforeJournal afterJournal afterMutation)
for phase in "${PHASES[@]}"; do
  for edge in "${EDGES[@]}"; do
    point="${phase}:${edge}"
    set_faults "$point"
    expect_kill "$point" "$RESTORE_ID" "$RESTORE_BUNDLE"
    recover_point "$point" "$RESTORE_APP" "$RESTORE_BUNDLE"
    pass "A33 recovered $point"
  done
done
pass 'A33 fault injection recovered every WAL phase edge'

# Leave a stubBack journal with no live owner: with --no-wait nobody adopts
# after the fault kills the detached watcher.
set_faults "stubBack:afterJournal"
run_cli launch "$RESTORE_ID" --no-wait || fail 'stubBack --no-wait launch'
stub_back_orphaned() {
  [[ "$(journal_field "$RESTORE_BUNDLE" phase 2>/dev/null)" == "stubBack" ]] || return 1
  local owner
  owner="$(journal_field "$RESTORE_BUNDLE" owner | python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])')" || return 1
  ! kill -0 "$owner" 2>/dev/null
}
wait_for 90 'watcher killed at stubBack:afterJournal' stub_back_orphaned
STAGING="$(journal_field "$RESTORE_BUNDLE" staging)" || fail 'stubBack journal has no staging path'
[[ -d "$STAGING/stub.app" ]] || fail "parked stub missing at $STAGING/stub.app before regeneration"
rm -rf "$STAGING/stub.app"
set_faults ""
run_cli gc || fail 'gc did not regenerate a missing stub'
assert_stub_terminal 'stub regeneration' "$RESTORE_APP" "$RESTORE_BUNDLE"
/usr/bin/codesign --verify --strict "$RESTORE_APP" >>"$LOG" 2>&1 || fail 'regenerated stub failed codesign --verify --strict'
pass 'missing parked stub was regenerated and signed'

# --- A33b / A34d: busy adoption, then a signed in-place update is retained ---
BUSY_BUNDLE=io.github.s546126.256isenough.e2ebusy
BUSY_APP="$TMP/Applications/RestoreBusy.app"
BUSY_HOLD="$TMP/restore-busy.hold"
BUSY_PID="$TMP/restore-busy.pid"
touch "$BUSY_HOLD"
make_app "$BUSY_APP" "$BUSY_BUNDLE" "RestoreBusy" "$BUSY_HOLD" "$BUSY_PID" "v1"
run_cli pack "$BUSY_APP" --mode restore --keep-original --stub-dir "$TMP/Applications" || fail 'pack busy restore fixture'
BUSY_ID="$(image_id_for "$BUSY_BUNDLE")"
[[ -n "$BUSY_ID" ]] || fail 'busy restore image id missing'

run_cli launch "$BUSY_ID" --no-wait || fail 'A33b --no-wait launch'
busy_restore_is_active() {
  [[ "$(bundle_id_of "$BUSY_APP")" == "$BUSY_BUNDLE" ]] || return 1
  local phase
  phase="$(journal_field "$BUSY_BUNDLE" phase 2>/dev/null)" || return 1
  [[ "$phase" == "active" ]]
}
wait_for 60 'busy restore reached active with the real bundle' busy_restore_is_active
OWNER="$(journal_field "$BUSY_BUNDLE" owner | python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])')"
kill -9 "$OWNER" 2>/dev/null || true
# Helper argv contains the destination path, so the probe stays busy even if
# the app's own command line is not visible yet.
tail -f "$BUSY_APP/Contents/Info.plist" >/dev/null &
HELPER=$!
BEFORE_ADOPTS="$(adopt_count "$BUSY_BUNDLE")"
run_cli gc &
GC1=$!
run_cli gc &
GC2=$!
wait "$GC1" || fail 'first concurrent gc failed'
wait "$GC2" || fail 'second concurrent gc failed'
AFTER_ADOPTS="$(adopt_count "$BUSY_BUNDLE")"
[[ $((AFTER_ADOPTS - BEFORE_ADOPTS)) -eq 1 ]] || fail "concurrent gc adopt count changed by $((AFTER_ADOPTS - BEFORE_ADOPTS)), expected 1"
NEW_OWNER="$(journal_field "$BUSY_BUNDLE" owner | python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])')"
ps -ax -o pid=,command= > "$TMP/ps.txt"
grep -E "^[[:space:]]*${NEW_OWNER} " "$TMP/ps.txt" | grep -q 'hook watch' || fail "journal owner $NEW_OWNER is not hook watch"
[[ "$(bundle_id_of "$BUSY_APP")" == "$BUSY_BUNDLE" ]] || fail 'A33b swapped the busy destination'
PARKED="$(journal_field "$BUSY_BUNDLE" staging)/stub.app"
[[ "$(bundle_id_of "$PARKED")" == "$BUSY_BUNDLE.256stub" ]] || fail 'A33b did not keep the parked stub'
python3 - "$STATE" "$BUSY_BUNDLE" <<'PY' || fail 'A33b retained a bundle while it was busy'
import json, sys
with open(sys.argv[1]) as fh:
    app = (json.load(fh).get("apps") or {}).get(sys.argv[2]) or {}
raise SystemExit(0 if "needsResolution" not in app else 1)
PY
pass 'A33b one watcher adopted a busy restore and left the real bundle in place'

# Stop the watcher before exchanging the destination so a clean probe cannot
# observe the missing bundle mid-rename.
kill -9 "$NEW_OWNER" 2>/dev/null || true
watcher_dead() { ! kill -0 "$NEW_OWNER" 2>/dev/null; }
wait_for 10 'killed watcher has exited' watcher_dead
mv "$BUSY_APP" "$TMP/aside-running.app"
make_app "$BUSY_APP" "$BUSY_BUNDLE" "RestoreBusy" "$BUSY_HOLD" "$BUSY_PID" "v1.1-updated"
# A resource change is not enough if cdhash is only the main executable.
# Swap in another valid Mach-O and re-sign. Appending bytes is not a Mach-O:
# macOS 27 codesign then fails with "main executable failed strict validation".
compile_restore_bin v1.1-updated "$TMP/restore-bin-v11"
cp "$TMP/restore-bin-v11" "$BUSY_APP/Contents/MacOS/Restore"
chmod 755 "$BUSY_APP/Contents/MacOS/Restore"
/usr/bin/codesign --force --sign - "$BUSY_APP" >>"$LOG" 2>&1 || fail 'codesign updated busy app'
/usr/bin/codesign --verify --strict "$BUSY_APP" >>"$LOG" 2>&1 || fail 'codesign --verify --strict updated busy app'
V1_CD="$(cdhash_of "$TMP/aside-running.app")"
V11_CD="$(cdhash_of "$BUSY_APP")"
[[ -n "$V1_CD" && -n "$V11_CD" && "$V1_CD" != "$V11_CD" ]] || fail "v1.1 cdhash '$V11_CD' did not change from '$V1_CD'"
# The helper still names the destination path, so the replacement stays busy.
run_cli gc || fail 'gc while updated bundle is busy'
[[ "$(bundle_id_of "$BUSY_APP")" == "$BUSY_BUNDLE" ]] || fail 'busy gc restored the stub over the updated bundle'
python3 - "$STATE" "$BUSY_BUNDLE" <<'PY' || fail 'busy gc retained the updated bundle before it was idle'
import json, sys
with open(sys.argv[1]) as fh:
    app = (json.load(fh).get("apps") or {}).get(sys.argv[2]) or {}
raise SystemExit(0 if "needsResolution" not in app else 1)
PY
pass 'A34d updated bundle is watched while busy and not retained yet'

kill "$HELPER" 2>/dev/null || true
wait "$HELPER" 2>/dev/null || true
HELPER=""
if [[ -f "$BUSY_PID" ]]; then kill -9 "$(cat "$BUSY_PID")" 2>/dev/null || true; fi
rm -f "$BUSY_HOLD"
update_was_retained() {
  [[ "$(bundle_id_of "$BUSY_APP")" == "$BUSY_BUNDLE.256stub" ]] || return 1
  python3 -c 'import json,sys; app=(json.load(open(sys.argv[1])).get("apps") or {}).get(sys.argv[2]) or {}; raise SystemExit(0 if isinstance(app.get("needsResolution"), dict) else 1)' "$STATE" "$BUSY_BUNDLE"
}
wait_for 60 'restore-out retained the update and returned the stub' update_was_retained
RECORD="$(app_record "$BUSY_BUNDLE")"
RETAINED="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["needsResolution"]["retainedPath"])' "$RECORD")"
STATE_CD="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["needsResolution"]["cdhash"])' "$RECORD")"
SIGN_CD="$(cdhash_of "$RETAINED/Contents/MacOS/Restore")"
BUNDLE_CD="$(cdhash_of "$RETAINED")"
[[ -n "$SIGN_CD" && "$SIGN_CD" == "$STATE_CD" ]] || fail "retained cdhash '$STATE_CD' != codesign '$SIGN_CD'"
[[ -n "$BUNDLE_CD" && "$BUNDLE_CD" == "$SIGN_CD" ]] || fail "bundle CDHash '$BUNDLE_CD' != executable '$SIGN_CD'"
OUTCOME="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["lastOutcome"]["name"])' "$RECORD")"
[[ "$OUTCOME" == "restoredOutRetained" ]] || fail "updated app outcome is '$OUTCOME'"
set +e
run_cli launch "$BUSY_ID"
RESOLVE_STATUS=$?
set -e
[[ "$RESOLVE_STATUS" -eq 14 ]] || fail "launch of an unresolved update exited $RESOLVE_STATUS, expected 14"
run_cli resolve "$BUSY_ID" --discard || fail 'resolve --discard'
pass 'A34d signed update was retained, blocked launch, and can be discarded'

# Release binary is a clean build. Faults are config, not a separate product.
swift build -c release >>"$LOG" 2>&1 || fail 'swift build -c release'
"$ROOT/.build/release/isenough" version >>"$LOG" 2>&1 || fail 'release isenough version'
pass 'release build answers version without a fault-enabled product'

# The mount-mode fixture image was corrupted above; leave the restore apps'
# journals closed so the final PASS line is the last assertion of e2e.sh.
assert_no_isenough_mounts 'after restore e2e'
