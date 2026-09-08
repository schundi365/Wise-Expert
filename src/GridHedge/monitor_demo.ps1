# GridHedge demo monitor — the honest scoreboard for the "+£24k" config.
# Shows the metric that matters: banked GREEN (closed profit) vs open FLOATING
# red vs current equity. The whole point: watch floating red grow over time.
$data="C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\92518C9899A1ED3884F29F1749EEC361"
$log = Get-ChildItem "$data\MQL5\Logs" -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(!$log){ Write-Output "no log found"; exit }

$lines = Get-Content $log.FullName -Encoding Unicode | Select-String -Pattern "GridHedge"

# count profit closes and their booked total from PROFIT log lines
$profits = $lines | Select-String "PROFIT ([\d\.]+)>=" | ForEach-Object {
  if($_ -match "PROFIT ([\d\.]+)>="){ [double]$Matches[1] }
}
$greenCount = ($profits | Measure-Object).Count
$greenSum   = ($profits | Measure-Object -Sum).Sum
$opened     = ($lines | Select-String " opened rc=").Count
$halts      = ($lines | Select-String "HALT|MAX FLOAT|EQ STOP|CLOSE ALL").Count

Write-Output "=== GridHedge demo scoreboard ($($log.Name)) ==="
Write-Output ("Positions opened : {0}" -f $opened)
Write-Output ("Green closes     : {0}   (banked ~ £{1:N2})" -f $greenCount, $greenSum)
Write-Output ("Halt/flush events: {0}   <-- watch this; when it fires, the floating red was realized" -f $halts)
Write-Output ""
Write-Output "--- last 12 events ---"
$lines | Select-Object -Last 12 | ForEach-Object { ($_ -split "\t")[-1] }
Write-Output ""
Write-Output "NOTE: 'banked green' looks great and keeps rising. The real story is the"
Write-Output "OPEN floating loss on the losing side (visible on the chart panel P/L), which"
Write-Output "is NOT in this log until it's force-closed. When a halt/flush event appears,"
Write-Output "that is the day the small floating red became a big realized loss."
