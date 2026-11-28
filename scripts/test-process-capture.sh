#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/disklessly-process-capture.XXXXXX")"
cleanup() {
  rm -f "$TMP/process-capture-probe"
  rmdir "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

swiftc \
  "$ROOT/Sources/DisklesslyCore/ProcessCapture.swift" \
  "$ROOT/Tests/ProcessCaptureIntegration/main.swift" \
  -o "$TMP/process-capture-probe"

"$TMP/process-capture-probe"
