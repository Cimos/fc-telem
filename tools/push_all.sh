#!/usr/bin/env bash
# Queue the core and all firmware profiles for the running USB console.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="$ROOT/debug/cmd.txt"
: > "$CMD"
printf '!push "%s" %s\n' "$(wslpath -w "$ROOT/SCRIPTS/TELEMETRY/fctel.lua")" "/SCRIPTS/TELEMETRY/fctel.lua" >> "$CMD"
for file in "$ROOT"/SCRIPTS/FCTEL/*.lua; do
  printf '!push "%s" %s\n' "$(wslpath -w "$file")" "/SCRIPTS/FCTEL/$(basename "$file")" >> "$CMD"
done
echo "queued core and profiles; watch debug/console-latest.log for PUSHOK or PUSHFAIL"
