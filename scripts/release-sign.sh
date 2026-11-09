#!/usr/bin/env bash
# Sign, notarize, staple, and package a release from build/Disklessly.app.
#
#   scripts/build-app.sh && scripts/release-sign.sh [--dry-run]
#
# Environment:
#   DISKLESSLY_SIGN_IDENTITY  "Developer ID Application: Name (TEAMID)". Unset means dry run.
#   NOTARY_PROFILE          keychain profile made with `xcrun notarytool store-credentials`.
#                           Unset skips notarization (the artifacts are signed, not notarized).
#   DISKLESSLY_BUILD_DIR      folder holding Disklessly.app, default <repo>/build
#   DISKLESSLY_DIST_DIR       output folder, default <repo>/dist
#   DISKLESSLY_KEYCHAIN       keychain to search for the identity (CI uses a temporary one)
#
# Output in DISKLESSLY_DIST_DIR:
#   disklessly-<ver>-macos-universal.tar.gz   bin/disklessly, bin/disklessly-stub, share/disklessly/web
#   Disklessly-<ver>.dmg                    Disklessly.app and an /Applications link
#   SHA256SUMS
#
# A dry run prints every codesign, notarytool, and stapler command instead of
# running it, then still builds the archives so the layout can be checked.
#
# Stubs that `disklessly pack` writes on a user's Mac stay ad-hoc signed by design.
# Each stub is generated per app on that Mac, so no Developer ID can sign it ahead
# of time, and it never leaves the Mac. Only the disklessly-stub template inside the
# release is signed with the release identity; pack copies it and re-signs the
# generated bundle ad-hoc (or with DISKLESSLY_SIGN_IDENTITY when the user sets one).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${DISKLESSLY_BUILD_DIR:-$ROOT/build}"
DIST="${DISKLESSLY_DIST_DIR:-$ROOT/dist}"
APP="$BUILD/Disklessly.app"
IDENTITY="${DISKLESSLY_SIGN_IDENTITY:-}"
PROFILE="${NOTARY_PROFILE:-}"
DRY=0
[[ "${1:-}" == "--dry-run" || -z "$IDENTITY" ]] && DRY=1

log() { printf 'release-sign: %s\n' "$*"; }
run() {
  if [[ $DRY -eq 1 ]]; then printf '[dry-run]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}

[[ -d "$APP" ]] || { echo "release-sign: $APP not found; run scripts/build-app.sh first" >&2; exit 66; }
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
[[ -n "$VERSION" ]] || { echo "release-sign: no CFBundleShortVersionString in $APP" >&2; exit 65; }
if [[ $DRY -eq 1 ]]; then log "dry run for $VERSION (set DISKLESSLY_SIGN_IDENTITY to sign)"; else log "signing $VERSION as $IDENTITY"; fi

SIGN=(/usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY")
[[ -n "${DISKLESSLY_KEYCHAIN:-}" ]] && SIGN+=(--keychain "$DISKLESSLY_KEYCHAIN")

# Inside-out: nested executables first, then the bundle (which signs the main executable).
[[ -x "$APP/Contents/MacOS/rclone" ]] && run "${SIGN[@]}" "$APP/Contents/MacOS/rclone"
run "${SIGN[@]}" "$APP/Contents/MacOS/disklessly-stub"
run "${SIGN[@]}" "$APP/Contents/MacOS/disklessly"
run "${SIGN[@]}" "$APP"
run /usr/bin/codesign --verify --strict --deep --verbose=2 "$APP"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

notarize() {
  local file="$1"
  if [[ -z "$PROFILE" ]]; then
    log "NOTARY_PROFILE unset; $(basename "$file") is not notarized"
    return 0
  fi
  local extra=()
  [[ -n "${DISKLESSLY_KEYCHAIN:-}" ]] && extra=(--keychain "$DISKLESSLY_KEYCHAIN")
  run /usr/bin/xcrun notarytool submit "$file" --keychain-profile "$PROFILE" ${extra[@]+"${extra[@]}"} --wait
}

# Notarize the app. The ticket covers the cdhashes of every signed binary inside,
# including the CLI copies that go into the tarball.
/usr/bin/ditto -c -k --keepParent "$APP" "$WORK/Disklessly.zip"
notarize "$WORK/Disklessly.zip"
[[ -n "$PROFILE" ]] && run /usr/bin/xcrun stapler staple "$APP"

rm -rf "$DIST"
mkdir -p "$DIST"

# CLI tarball, laid out like a Homebrew keg: bin/ and share/disklessly/web.
TARBASE="disklessly-$VERSION-macos-universal"
STAGE="$WORK/$TARBASE"
mkdir -p "$STAGE/bin" "$STAGE/share/disklessly"
cp "$APP/Contents/MacOS/disklessly" "$APP/Contents/MacOS/disklessly-stub" "$STAGE/bin/"
cp -R "$APP/Contents/Resources/web" "$STAGE/share/disklessly/web"
cp "$ROOT/LICENSE" "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/PRIVACY.md" "$STAGE/"
COPYFILE_DISABLE=1 /usr/bin/tar -C "$WORK" -czf "$DIST/$TARBASE.tar.gz" "$TARBASE"

# DMG with the app and a link to /Applications.
DMGSRC="$WORK/dmg"
mkdir -p "$DMGSRC"
/usr/bin/ditto "$APP" "$DMGSRC/Disklessly.app"
ln -s /Applications "$DMGSRC/Applications"
DMG="$DIST/Disklessly-$VERSION.dmg"
/usr/bin/hdiutil create -quiet -volname "Disklessly $VERSION" -srcfolder "$DMGSRC" -fs HFS+ -format UDZO -ov "$DMG"
SIGN_DMG=(/usr/bin/codesign --force --timestamp --sign "$IDENTITY")
[[ -n "${DISKLESSLY_KEYCHAIN:-}" ]] && SIGN_DMG+=(--keychain "$DISKLESSLY_KEYCHAIN")
run "${SIGN_DMG[@]}" "$DMG"
notarize "$DMG"
[[ -n "$PROFILE" ]] && run /usr/bin/xcrun stapler staple "$DMG"

(cd "$DIST" && /usr/bin/shasum -a 256 "$TARBASE.tar.gz" "Disklessly-$VERSION.dmg" >SHA256SUMS)
if [[ $DRY -eq 0 ]]; then
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP" || log "spctl rejected the app (expected before notarization)"
fi
log "artifacts in $DIST:"
cat "$DIST/SHA256SUMS"
[[ $DRY -eq 1 ]] && log "dry run: nothing was signed or notarized"
exit 0
