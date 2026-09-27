#!/usr/bin/env bash
# Send the current script to the radio over the running USB console (tools/console.sh).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "!push $(wslpath -w "$ROOT/SCRIPTS/TELEMETRY/fctel.lua")" > "$ROOT/debug/cmd.txt"
echo "queued; watch debug/console-latest.log for PUSHOK or PUSHFAIL"
