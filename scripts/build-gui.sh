#!/usr/bin/env bash
set -euo pipefail
command -v pake >/dev/null || { echo 'Install Pake CLI first: cargo install pake-cli' >&2; exit 1; }
pake http://127.0.0.1:47256/ui/ --name 256isenough --show-system-tray --start-on-login
