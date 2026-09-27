#!/usr/bin/env bash
# Send a file to the radio over the running USB console.
# Usage: tools/push.sh [local-file] [radio-path]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="${1:-$ROOT/SCRIPTS/TELEMETRY/fctel.lua}"
DEST="${2:-/SCRIPTS/TELEMETRY/fctel.lua}"
echo "!push \"$(wslpath -w "$FILE")\" $DEST" > "$ROOT/debug/cmd.txt"
echo "queued; watch debug/console-latest.log for PUSHOK or PUSHFAIL"
