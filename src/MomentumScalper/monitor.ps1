# MomentumScalper live/demo forward-test monitor.
# Scrapes the terminal Experts log for MScalp activity and prints a running tally.
# Usage:  powershell -ExecutionPolicy Bypass -File monitor.ps1
$data = "C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\92518C9899A1ED3884F29F1749EEC361"
$log  = Get-ChildItem "$data\MQL5\Logs" -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(!$log){ Write-Output "no log found"; exit }

$lines = Get-Content $log.FullName -Encoding Unicode | Select-String -Pattern "MScalp"
$entries = $lines | Select-String -Pattern "BUY .* SL=| SELL .* SL="   # actual order placements
$buys    = ($lines | Select-String "\[MScalp\] BUY ").Count
$sells   = ($lines | Select-String "\[MScalp\] SELL ").Count
$fails   = ($lines | Select-String "failed rc=").Count
$trails  = ($lines | Select-String " trail SL ").Count

Write-Output "=== MomentumScalper monitor ($($log.Name)) ==="
Write-Output ("Orders placed : BUY {0}  SELL {1}   (failed: {2})" -f $buys,$sells,$fails)
Write-Output ("Stop moves    : {0}" -f $trails)
Write-Output ""
Write-Output "--- last 15 MScalp events ---"
$lines | Select-Object -Last 15 | ForEach-Object { ($_ -split "\t")[-1] }
Write-Output ""
Write-Output "--- skip reasons seen (counts) ---"
$lines | Select-String "skip: " | ForEach-Object { (($_ -split "skip: ")[-1]).Trim() } |
  Group-Object | Sort-Object Count -Descending | Select-Object -First 10 |
  ForEach-Object { "{0,4}  {1}" -f $_.Count, $_.Name }
