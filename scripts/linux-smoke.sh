#!/usr/bin/env bash
# Smoke-run a Linux disklessly binary as an unprivileged user in a throwaway home.
# Usage: scripts/linux-smoke.sh /path/to/disklessly   (run as root inside a container)
set -euo pipefail
BIN="$(readlink -f "$1")"
BIN_DIR="$(dirname "$BIN")"
fail() { echo "smoke: FAIL: $*" >&2; exit 1; }

if [ "$(id -u)" = 0 ]; then
  id smoke >/dev/null 2>&1 || useradd -m smoke
  chmod -R a+rX "$BIN_DIR"
  exec su smoke -c "bash $(readlink -f "$0") $BIN"
fi

# Foundation takes the home folder from passwd, not $HOME, so this runs in the
# smoke user's own (fresh) home.
export HOME="$(getent passwd "$(id -un)" | cut -d: -f6)"
cd "$HOME"
D() { "$BIN" "$@"; }

D version | grep -q '^disklessly ' || fail "version"
D help | grep -q 'Linux build' || fail "help is not the Linux text"
D init >/dev/null || fail "init"
[ -d "$HOME/.local/share/disklessly/repo" ] || fail "repo not under XDG data dir"
[ ! -e "$HOME/Applications" ] || fail "init created a stub folder"

# App commands are refused with exit 3 and a clear message.
for cmd in pack launch unpack recommend gc doctor "stub refresh --all"; do
  set +e; out="$(D $cmd 2>&1)"; code=$?; set -e
  [ "$code" = 3 ] || fail "$cmd exited $code"
  echo "$out" | grep -q 'macOS only' || fail "$cmd message: $out"
done
out="$(D --json pack x.app || true)"
echo "$out" | grep -q '"EX_UNSUPPORTED"' || fail "pack --json: $out"

# Sessions: an old session is archived, one held open is skipped, then search and restore.
proj="$HOME/.claude/projects/demo"
mkdir -p "$proj"
printf '{"type":"user","message":"needle-old"}\n' > "$proj/old.jsonl"
printf '{"type":"user","message":"needle-live"}\n' > "$proj/live.jsonl"
touch -d '60 days ago' "$proj/old.jsonl" "$proj/live.jsonl"
exec 3>>"$proj/live.jsonl"
D sessions --json >/dev/null || fail "sessions dry run"
D sessions --apply --days 30 > apply.json || fail "sessions --apply"
exec 3>&-
[ ! -e "$proj/old.jsonl" ] || fail "old session was not archived"
[ -e "$proj/live.jsonl" ] || fail "an open session was archived"
grep -q 'live.jsonl' apply.json || fail "open session not reported as skipped"
D sessions search needle-old | grep -q 'old.jsonl' || fail "search"
D sessions restore old.jsonl >/dev/null || fail "restore"
grep -q needle-old "$proj/old.jsonl" || fail "restored content"

# Encrypted archive with the key in the 0600 secrets file (no D-Bus here).
D sessions key init >/dev/null || fail "key init"
secrets="$HOME/.config/disklessly/secrets.json"
[ "$(stat -c %a "$secrets")" = 600 ] || fail "secrets file mode"
[ "$(stat -c %a "$(dirname "$secrets")")" = 700 ] || fail "secrets dir mode"
printf '{"type":"user","message":"needle-secret"}\n' > "$proj/enc.jsonl"
touch -d '60 days ago' "$proj/enc.jsonl"
D sessions --apply --days 30 --encrypt >/dev/null || fail "encrypted apply"
[ ! -e "$proj/enc.jsonl" ] || fail "encrypted session not archived"
D sessions restore enc.jsonl >/dev/null || fail "encrypted restore"
grep -q needle-secret "$proj/enc.jsonl" || fail "encrypted content"

# Backends and devices.
mkdir -p "$HOME/share"
D backend add smb --host nas --share s --mount "$HOME/share" --id nas >/dev/null 2>&1 || true
D backend list | grep -q '"id"' || echo "smoke: note: backend add smb without a mounted share was refused (expected without a share)"
D devices >/dev/null || fail "devices"
D license | grep -qi 'free\|licen' || fail "license"

# Dashboard: status says linux, app routes answer 501, usage scan finishes.
# Start the binary itself (not through the D function) so $! is the server's pid; backgrounding
# a function forks a subshell, and killing that left the server running with this script's stdout.
"$BIN" ui --json > ui.json & UI=$!
trap 'kill "$UI" 2>/dev/null || true' EXIT
for _ in $(seq 50); do [ -s ui.json ] && break; sleep 0.1; done
url="$(sed -E 's/.*"url":"([^"]+)".*/\1/' ui.json)"
base="${url%%/?token=*}"; token="${url##*token=}"
get() { curl -fsS -H "Authorization: Bearer $token" "$base$1?token=$token" "${@:2}"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$base$1?token=$token" "${@:2}"; }
curl -fsS "$url" | grep -q '<html' || fail "index.html"
get /api/status | grep -q '"platform":"linux"' || fail "status platform"
[ "$(code /api/recommend)" = 501 ] || fail "recommend not refused"
[ "$(code /api/pack -X POST -H 'Content-Type: application/json' -d '{"app":"x"}')" = 501 ] || fail "pack job not refused"
get /api/usage/scan -X POST -H 'Content-Type: application/json' -d '{}' >/dev/null || fail "usage scan"
for _ in $(seq 100); do get /api/usage | grep -q '"state":"ready"' && break; sleep 0.2; done
get /api/usage | grep -q '"appdata"\|"personal"' || fail "usage tree"
kill $UI; wait $UI 2>/dev/null || true

echo "smoke: OK"
