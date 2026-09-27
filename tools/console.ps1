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
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
  try { $line = $sp.ReadLine().TrimEnd("`r"); if ($line) { Write-Output ((Get-Date).ToString("HH:mm:ss.fff") + " " + $line) } } catch [System.TimeoutException] {}
  if ($CmdFile -and (Test-Path $CmdFile)) {
    $cmds = Get-Content $CmdFile; Remove-Item $CmdFile
    foreach ($c in $cmds) { if ($c) { $sp.Write($c + "`n"); Write-Output ((Get-Date).ToString("HH:mm:ss.fff") + " >> " + $c) } }
  }
}
$sp.Close()
