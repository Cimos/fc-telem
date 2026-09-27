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
# Print straight to stdout. Inside a function, Write-Output would become part of the
# function's return value instead of reaching the console.
function Say([string]$text) { [Console]::Out.WriteLine($text); [Console]::Out.Flush() }
# Read lines until one matches $pattern or $secs pass. Prints everything it reads and
# returns only the matching line (or $null).
function Wait-Line([string]$pattern, [double]$secs) {
  $until = (Get-Date).AddSeconds($secs)
  while ((Get-Date) -lt $until) {
    try { $l = $sp.ReadLine().TrimEnd("`r") } catch [System.TimeoutException] { continue }
    if ($l) { Say ((Stamp) + " " + $l); if ([regex]::IsMatch($l, $pattern)) { return $l } }
  }
  return $null
}
# Send bytes [offset..end) in 128-byte chunks, each acked with "UACK <bytes so far>".
function Send-Body([byte[]]$bytes, [int]$offset) {
  for ($off = $offset; $off -lt $bytes.Length; $off += 128) {
    $n = [Math]::Min(128, $bytes.Length - $off); $sp.Write($bytes, $off, $n); $want = $off + $n
    $ok = $false; $until = (Get-Date).AddSeconds(4)
    while (-not $ok -and (Get-Date) -lt $until) {
      $l = Wait-Line '^(UACK|UERR)' 1
      if ($l -and $l.StartsWith("UERR")) { Say ((Stamp) + " PUSHFAIL " + $l); return $false }
      $m = if ($l) { [regex]::Match($l, '^UACK (\d+)') } else { $null }
      if ($m -and $m.Success -and [int]$m.Groups[1].Value -ge $want) { $ok = $true }
    }
    if (-not $ok) { Say ((Stamp) + " PUSHFAIL no ack at " + $want); return $false }
  }
  $fin = Wait-Line '^(UDONE|UERR)' 8
  if ($fin -and $fin.StartsWith("UDONE")) { Say ((Stamp) + " PUSHOK"); return $true }
  Say ((Stamp) + " PUSHFAIL end=" + $fin); return $false
}
# Send a file to the script's updater: "U size sum [path]", then the body.
function Push-File([string]$path, [string]$destination) {
  if (-not $destination) { $destination = "/SCRIPTS/TELEMETRY/fctel.lua" }
  $bytes = [System.IO.File]::ReadAllBytes($path); $sum = 0
  foreach ($b in $bytes) { $sum = ($sum + $b) % 65536 }
  Say ((Stamp) + " >> PUSH " + $path + " -> " + $destination + " " + $bytes.Length + " bytes sum " + $sum)
  $sp.Write("U " + $bytes.Length + " " + $sum + " " + $destination + "`n")
  if (-not (Wait-Line '^(UOK|UERR)' 4)) { Say ((Stamp) + " PUSHFAIL no UOK"); return }
  [void](Send-Body $bytes 0)
}
# Continue an interrupted push: send the rest of the body without a new header.
function Resume-File([string]$path, [int]$offset) {
  $bytes = [System.IO.File]::ReadAllBytes($path)
  Say ((Stamp) + " >> RESUME " + $path + " from " + $offset + " of " + $bytes.Length)
  [void](Send-Body $bytes $offset)
}
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
  try { $line = $sp.ReadLine().TrimEnd("`r"); if ($line) { Write-Output ((Get-Date).ToString("HH:mm:ss.fff") + " " + $line) } } catch [System.TimeoutException] {}
  if ($CmdFile -and (Test-Path $CmdFile)) {
    $cmds = Get-Content $CmdFile; Remove-Item $CmdFile
    foreach ($c in $cmds) {
      $m1 = [regex]::Match($c, '^!push\s+"([^"]+)"(?:\s+(\S+))?$')
      $m2 = [regex]::Match($c, '^!push\s+(\S+)(?:\s+(\S+))?$')
      $m3 = [regex]::Match($c, '^!resume\s+"([^"]+)"\s+(\d+)$')
      try {
        if ($m1.Success) { Push-File $m1.Groups[1].Value $m1.Groups[2].Value }
        elseif ($m3.Success) { Resume-File $m3.Groups[1].Value ([int]$m3.Groups[2].Value) }
        elseif ($m2.Success) { Push-File $m2.Groups[1].Value $m2.Groups[2].Value }
        elseif ($c) { $sp.Write($c + "`n"); Say ((Stamp) + " >> " + $c) }
      } catch { Say ((Stamp) + " PUSHFAIL exception " + $_.Exception.Message) }
    }
  }
}
$sp.Close()
