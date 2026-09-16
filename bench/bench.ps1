# Runs the capture bench exe for -Seconds, sampling process memory/CPU every
# -Interval seconds, then kills it and prints a summary. Usage:
#   pwsh -File bench.ps1 -Exe <path\to\flutter_webrtc_example.exe> -Label before -Seconds 40
param(
  [Parameter(Mandatory)] [string] $Exe,
  [Parameter(Mandatory)] [string] $Label,
  [int] $Seconds = 40,
  [int] $Interval = 5
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'capture_bench.log'
if (Test-Path $log) { Remove-Item $log -Force }
$out = Join-Path $PSScriptRoot "bench_$Label.txt"

$p = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
"launched pid=$($p.Id) exe=$Exe" | Tee-Object -FilePath $out

# Wait for the camera to open (BENCH ready) or give up after 30 s.
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
  if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'BENCH ready' -Quiet)) { break }
  if ($p.HasExited) { "process exited early (code $($p.ExitCode))" | Tee-Object -FilePath $out -Append; exit 1 }
  Start-Sleep -Milliseconds 250
}
if (-not (Select-String -Path $log -Pattern 'BENCH ready' -Quiet)) {
  "camera never became ready; log:" | Tee-Object -FilePath $out -Append
  Get-Content $log | Tee-Object -FilePath $out -Append
  Stop-Process -Id $p.Id -Force; exit 1
}

function Sample($proc) {
  $proc.Refresh()
  $m = Select-String -Path $log -Pattern 'BENCH n=(\d+)' | Select-Object -Last 1
  [int] $n = 0
  if ($m) { $n = [int] $m.Matches[0].Groups[1].Value }
  [pscustomobject]@{
    t      = (Get-Date)
    privMB = [math]::Round($proc.PrivateMemorySize64 / 1MB, 1)
    wsMB   = [math]::Round($proc.WorkingSet64 / 1MB, 1)
    cpuS   = [math]::Round($proc.TotalProcessorTime.TotalSeconds, 2)
    n      = $n
  }
}

$samples = @()
$samples += Sample $p
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
  Start-Sleep -Seconds $Interval
  if ($p.HasExited) { "process exited during run (code $($p.ExitCode))" | Tee-Object -FilePath $out -Append; break }
  $samples += Sample $p
}
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue

"" | Tee-Object -FilePath $out -Append
"--- samples ($Label) ---" | Tee-Object -FilePath $out -Append
$samples | Format-Table @{n='t';e={$_.t.ToString('HH:mm:ss')}}, privMB, wsMB, cpuS, n -AutoSize | Out-String -Width 100 | Tee-Object -FilePath $out -Append

$first = $samples[0]; $last = $samples[-1]
$wall = ($last.t - $first.t).TotalSeconds
$caps = $last.n - $first.n
$leakMB = $last.privMB - $first.privMB
$cpuCores = if ($wall -gt 0) { [math]::Round(($last.cpuS - $first.cpuS) / $wall, 2) } else { 0 }
"--- summary ($Label) ---" | Tee-Object -FilePath $out -Append
"wall s:              $([math]::Round($wall,1))" | Tee-Object -FilePath $out -Append
"captures in window:  $caps  ($([math]::Round($caps / [math]::Max($wall,1), 1))/s)" | Tee-Object -FilePath $out -Append
"private bytes delta: $leakMB MB  ($(if ($caps -gt 0) { [math]::Round($leakMB / $caps, 2) } else { 'n/a' }) MB per capture)" | Tee-Object -FilePath $out -Append
"cpu cores avg:       $cpuCores" | Tee-Object -FilePath $out -Append
"" | Tee-Object -FilePath $out -Append
"--- app log lines (ready / slow / errors / last stat) ---" | Tee-Object -FilePath $out -Append
Select-String -Path $log -Pattern 'BENCH (ready|slow|error|getUserMedia)' | ForEach-Object { $_.Line } | Tee-Object -FilePath $out -Append
(Select-String -Path $log -Pattern 'BENCH n=' | Select-Object -Last 1).Line | Tee-Object -FilePath $out -Append
