param([Parameter(Mandatory)][string]$Exe, [int]$MaxSeconds = 90)
$log = Join-Path $env:TEMP 'timeout_bench.log'
if (Test-Path $log) { Remove-Item $log -Force }
$p = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
"launched pid=$($p.Id)"
$deadline = (Get-Date).AddSeconds($MaxSeconds)
while ((Get-Date) -lt $deadline) {
  if ($p.HasExited) { "process exited early (code $($p.ExitCode))"; break }
  if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'TB done' -Quiet)) { break }
  Start-Sleep -Milliseconds 250
}
Start-Sleep -Milliseconds 500
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
"--- timeout_bench.log ---"
if (Test-Path $log) { Get-Content $log } else { "(no log written)" }
