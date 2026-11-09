#!/usr/bin/env bash
# Stamp the version, commit, and build date into EngineInstall.swift.
#
#   scripts/gen-version.sh            rewrite the GENERATED VERSION block
#   scripts/gen-version.sh --print    print the version that would be written, change nothing
#
# The version comes from DISKLESSLY_VERSION, else the newest v* tag reachable from
# HEAD (`git describe`), else the value already in the file. Commits after the tag
# keep the tag's version; `commit` says which build it is. SOURCE_DATE_EPOCH, when
# set, fixes the build date for reproducible builds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/Sources/DisklesslyEngine/EngineInstall.swift"

current="$(sed -n 's/^    public static let version = "\(.*\)"$/\1/p' "$FILE" | head -n 1)"
version="${DISKLESSLY_VERSION:-}"
if [[ -z "$version" ]]; then
  tag="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
  version="${tag#v}"
fi
version="${version:-$current}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "gen-version: '$version' is not a semantic version" >&2
  exit 65
fi

if [[ "${1:-}" == "--print" ]]; then
  echo "$version"
  exit 0
fi

commit="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
if [[ "$commit" != unknown ]] && [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no -- . ':!Sources/DisklesslyEngine/EngineInstall.swift' 2>/dev/null)" ]]; then
  commit="$commit-dirty"
fi
if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
  built="$(date -u -r "$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
else
  built="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

grep -q '// BEGIN GENERATED VERSION' "$FILE" || { echo "gen-version: marker missing in $FILE" >&2; exit 70; }
tmp="$(mktemp)"
awk -v v="$version" -v c="$commit" -v d="$built" '
  /\/\/ BEGIN GENERATED VERSION/ { print; print "    public static let version = \"" v "\""; print "    public static let commit = \"" c "\""; print "    public static let buildDate = \"" d "\""; skip = 1; next }
  /\/\/ END GENERATED VERSION/ { skip = 0 }
  !skip { print }
' "$FILE" >"$tmp"
cat "$tmp" >"$FILE"
rm -f "$tmp"
echo "gen-version: $version ($commit, $built)"
