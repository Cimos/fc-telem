#!/usr/bin/env bash
# Live USB console for the radio. Lines go to stdout and debug/console-<stamp>.log.
# Send a command from another shell:  echo d > debug/cmd.txt   (d, v, s, p1..p3, e)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; mkdir -p "$ROOT/debug"
LOG="$ROOT/debug/console-$(date +%Y%m%d-%H%M%S).log"
ln -sf "$(basename "$LOG")" "$ROOT/debug/console-latest.log"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$ROOT/tools/console.ps1")" \
  -CmdFile "$(wslpath -w "$ROOT/debug/cmd.txt")" -Seconds "${1:-3600}" 2>&1 | sed -u 's/\r$//' | tee "$LOG"
