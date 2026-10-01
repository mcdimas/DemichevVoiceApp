#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Debug/Build/Products/Debug/Demichev Voice.app/Contents/MacOS/DemichevVoice"
test -f "$APP"
test -f "${1:?Supply a local synthetic audio fixture}"
# Network is denied only for the child process, never for the whole Mac.
/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' "$APP" --check-audio "$1"
