#!/usr/bin/env bash
# Live USB console for the radio. Lines go to stdout and debug/console-<stamp>.log.
# Reconnects by itself after an unplug. PORT=COM22 tools/console.sh pins the port
# (use it when a flight controller is also plugged in; they share the USB id). Send a command from another shell:
#   echo d > debug/cmd.txt   (d, v, s, p1..p3, e)     tools/push.sh  (send the script)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; mkdir -p "$ROOT/debug"
DUR="${1:-3600}"; END=$((SECONDS + DUR))
LOG="$ROOT/debug/console-$(date +%Y%m%d-%H%M%S).log"
ln -sf "$(basename "$LOG")" "$ROOT/debug/console-latest.log"
while [ $SECONDS -lt $END ]; do
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$ROOT/tools/console.ps1")" \
    -Port "${PORT:-}" -CmdFile "$(wslpath -w "$ROOT/debug/cmd.txt")" -Seconds "$((END - SECONDS))" 2>&1 \
    | sed -u 's/\r$//' | grep --line-buffered -vE '^\s*(\+ |At |$)' | tee -a "$LOG"
  echo "$(date +%H:%M:%S.000) DISCONNECTED, waiting for the radio" | tee -a "$LOG"
  sleep 2
done
