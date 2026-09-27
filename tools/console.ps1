# Stream the radio's USB serial (VCP, port function LUA) to stdout and forward commands.
# Usage: powershell -File console.ps1 [-Port COM7] [-CmdFile path] [-Seconds 3600]
param([string]$Port = "", [string]$CmdFile = "", [int]$Seconds = 3600)
$ErrorActionPreference = "Stop"
if (-not $Port) {
  $waitEnd = (Get-Date).AddSeconds($Seconds); $said = $false
  do {
    $cands = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match '\(COM\d+\)' -and $_.PNPDeviceID -match 'VID_0483&PID_5740' })
    if (-not $cands) { if (-not $said) { Write-Output "WAITING: set USB-VCP to LUA on the radio, plug in, choose USB Serial (VCP)"; $said = $true }; Start-Sleep 2 }
  } while (-not $cands -and (Get-Date) -lt $waitEnd)
  foreach ($c in $cands) { Write-Output ("CANDIDATE " + $c.Name + " " + $c.PNPDeviceID) }
  if (-not $cands) { Write-Output "NO_PORT"; exit 2 }
  # Prefer the one that is not an INAV flight controller (both use 0483:5740): try each, keep the one that talks.
  foreach ($c in $cands) {
    $name = [regex]::Match($c.Name, 'COM\d+').Value
    try {
      $sp = New-Object System.IO.Ports.SerialPort $name, 115200
      $sp.DtrEnable = $true; $sp.ReadTimeout = 300; $sp.Open()
      $deadline = (Get-Date).AddSeconds(3); $seen = $false
      while ((Get-Date) -lt $deadline) { try { $l = $sp.ReadLine(); if ($l -match '^(START|EV|ERR|OK|\d+ fm=)') { $seen = $true; break } } catch {} }
      $sp.Close()
      if ($seen) { $Port = $name; break }
    } catch { Write-Output ("SKIP " + $name + " " + $_.Exception.Message) }
  }
  if (-not $Port) { $Port = [regex]::Match($cands[0].Name, 'COM\d+').Value; Write-Output "NO_TRAFFIC_YET using $Port" }
}
Write-Output "PORT $Port"
$sp = New-Object System.IO.Ports.SerialPort $Port, 115200
$sp.DtrEnable = $true; $sp.ReadTimeout = 200; $sp.NewLine = "`n"; $sp.Open()
function Stamp { (Get-Date).ToString("HH:mm:ss.fff") }
# Read lines until one matches $pattern or $secs pass. Prints everything it reads.
function Wait-Line([string]$pattern, [double]$secs) {
  $until = (Get-Date).AddSeconds($secs)
  while ((Get-Date) -lt $until) {
    try { $l = $sp.ReadLine().TrimEnd("`r") } catch [System.TimeoutException] { continue }
    if ($l) { Write-Output ((Stamp) + " " + $l); if ($l -match $pattern) { return $l } }
  }
  return $null
}
# Send a file to the script's updater: "U size sum", then 128-byte chunks, each acked.
function Push-File([string]$path) {
  $bytes = [System.IO.File]::ReadAllBytes($path); $sum = 0
  foreach ($b in $bytes) { $sum = ($sum + $b) % 65536 }
  Write-Output ((Stamp) + " >> PUSH $path $($bytes.Length) bytes sum $sum")
  $sp.Write("U $($bytes.Length) $sum`n")
  if (-not (Wait-Line '^UOK' 4)) { Write-Output ((Stamp) + " PUSHFAIL no UOK"); return }
  for ($off = 0; $off -lt $bytes.Length; $off += 128) {
    $n = [Math]::Min(128, $bytes.Length - $off); $sp.Write($bytes, $off, $n); $want = $off + $n
    $ok = $false; $until = (Get-Date).AddSeconds(4)
    while (-not $ok -and (Get-Date) -lt $until) {
      $l = Wait-Line '^(UACK|UERR)' 1
      if ($l -match '^UERR') { Write-Output ((Stamp) + " PUSHFAIL $l"); return }
      if ($l -match '^UACK (\d+)' -and [int]$Matches[1] -ge $want) { $ok = $true }
    }
    if (-not $ok) { Write-Output ((Stamp) + " PUSHFAIL no ack at $want"); return }
  }
  $end = Wait-Line '^(UDONE|UERR)' 8
  if ($end -match '^UDONE') { Write-Output ((Stamp) + " PUSHOK") } else { Write-Output ((Stamp) + " PUSHFAIL end=$end") }
}
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
  try { $line = $sp.ReadLine().TrimEnd("`r"); if ($line) { Write-Output ((Get-Date).ToString("HH:mm:ss.fff") + " " + $line) } } catch [System.TimeoutException] {}
  if ($CmdFile -and (Test-Path $CmdFile)) {
    $cmds = Get-Content $CmdFile; Remove-Item $CmdFile
    foreach ($c in $cmds) {
      if ($c -match '^!push (.+)$') { Push-File $Matches[1].Trim() }
      elseif ($c) { $sp.Write($c + "`n"); Write-Output ((Stamp) + " >> " + $c) }
    }
  }
}
$sp.Close()
