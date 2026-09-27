#!/usr/bin/env bash
# Wait for the radio's SD card (USB Storage mode), pull the debug log,
# push the current script. Usage: tools/sync.sh [--no-push] [--wait SECONDS]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUSH=1; WAIT=900
while [ $# -gt 0 ]; do case "$1" in --no-push) PUSH=0;; --wait) WAIT="$2"; shift;; esac; shift; done
find_card() {
  powershell.exe -NoProfile -Command "foreach (\$d in (Get-PSDrive -PSProvider FileSystem)) { \$r=\$d.Root; if ((Test-Path (\$r+'SCRIPTS')) -and (Test-Path (\$r+'MODELS'))) { Write-Output \$r } }" 2>/dev/null | tr -d '\r' | head -1
}
end=$((SECONDS + WAIT)); CARD=""
while [ -z "$CARD" ] && [ $SECONDS -lt $end ]; do CARD="$(find_card)"; [ -z "$CARD" ] && sleep 3; done
[ -z "$CARD" ] && { echo "no EdgeTX card within ${WAIT}s"; exit 2; }
echo "card: $CARD"
STAMP="$(date +%Y%m%d-%H%M%S)"
WSRC="$(wslpath -w "$ROOT/SCRIPTS/TELEMETRY/fctel.lua")"
WDBG="$(wslpath -w "$ROOT/debug")"
WSND="$(wslpath -w "$ROOT/SOUNDS/en/fctel")"
powershell.exe -NoProfile -Command "
  \$log = '${CARD}LOGS\fctel_dbg.txt'
  if (Test-Path \$log) { Copy-Item \$log '$WDBG\fctel_dbg-$STAMP.txt'; Write-Output 'pulled log' } else { Write-Output 'no log on card' }
  if ($PUSH -eq 1) { New-Item -ItemType Directory -Force -Path '${CARD}SCRIPTS\TELEMETRY' | Out-Null; Copy-Item '$WSRC' '${CARD}SCRIPTS\TELEMETRY\fctel.lua' -Force; if (Test-Path \$log) { Remove-Item \$log }; Write-Output 'pushed script, cleared log'; New-Item -ItemType Directory -Force -Path '${CARD}SOUNDS\en\fctel' | Out-Null; Copy-Item '$WSND\*.wav' '${CARD}SOUNDS\en\fctel\' -Force; Write-Output ('pushed ' + (Get-ChildItem '${CARD}SOUNDS\en\fctel' -Filter *.wav).Count + ' voice clips') }
" 2>&1 | tr -d '\r'
L="$ROOT/debug/fctel_dbg-$STAMP.txt"
if [ -f "$L" ]; then
  echo "--- errors"; grep -a '^ERR' "$L" | sort | uniq -c | head -20 || true
  echo "--- last lines"; tail -n 8 "$L"
fi
