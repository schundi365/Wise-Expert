# SessionEdge refinement: is the London-open edge ROBUST or a lucky pick?
# Sweep session hour (6/7/8), range length (30/60/90), R (1.0/1.5/2.0) across the
# 4 clearly-positive symbols. Real ticks Mar20-Jul24. Aggregate per config.
# ROBUSTNESS TEST: if neighbours of 7:00 also work, edge is real; if only 7:00, fragile.
$ErrorActionPreference="Stop"
$term="C:\Users\srika\Trading\Pepperstone\terminal64.exe"
$data="C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\98B028FE55E86F6449ABBE8302BC7D42"
$iniDir="c:\Users\srika\Labs\AgenticAI\Expert Trader\Wise Trader\src\SessionEdge\refine"
if(!(Test-Path $iniDir)){ New-Item -ItemType Directory -Path $iniDir -Force | Out-Null }

$symbols=@("XAUUSD","XAGUSD","GBPUSD","USDCHF")
# config variants: hour, range, R
$configs=@(
  @{id="h6_r60_R15"; hour=6; rng=60; R=1.5},
  @{id="h7_r60_R15"; hour=7; rng=60; R=1.5},   # the known-good baseline
  @{id="h8_r60_R15"; hour=8; rng=60; R=1.5},
  @{id="h7_r30_R15"; hour=7; rng=30; R=1.5},
  @{id="h7_r90_R15"; hour=7; rng=90; R=1.5},
  @{id="h7_r60_R10"; hour=7; rng=60; R=1.0},
  @{id="h7_r60_R20"; hour=7; rng=60; R=2.0}
)
function New-Ini($sym,$c,$report){
@"
[Tester]
Expert=SessionEdge\SessionEdge.ex5
Symbol=$sym
Period=M5
Model=4
Optimization=0
FromDate=2026.03.20
ToDate=2026.07.24
ForwardMode=0
Deposit=10000
Currency=GBP
Leverage=1:100
ExecutionMode=0
Report=$report
ReplaceReport=1
ShutdownTerminal=1
Visual=0

[TesterInputs]
InpRiskMoney=10.0
InpRewardRatio=$($c.R)
InpMaxLot=1.00
InpMinLot=0.01
InpSessionHour=$($c.hour)
InpRangeMins=$($c.rng)
InpFlatHour=20
InpBufferPoints=20
InpOneTradePerDay=true
InpStopFromRange=true
InpAtrPeriod=14
InpStopAtrMult=1.5
InpBeTriggerR=1.0
InpMaxSpreadPts=60
InpAvoidRollover=true
InpRolloverHour=23
InpMagic=77052024
InpSlippage=40
InpShowPanel=false
InpEnableLog=false
"@
}
function GS($text,$l){ $m=[regex]::Match($text,[regex]::Escape($l)+"[^A-Za-z]{0,45}"); if($m.Success){return ($m.Value -replace [regex]::Escape($l),'').Trim()}; return "" }
function TN($s){ $x=($s -replace '[^\d\.\-]',''); if($x -eq '' -or $x -eq '-'){return 0}; return [double]$x }

foreach($c in $configs){
  $sN=0.0;$sT=0;$sGP=0.0;$sGL=0.0
  foreach($sym in $symbols){
    $report="ORBr_${sym}_$($c.id)"; $ini=Join-Path $iniDir "${sym}_$($c.id).ini"
    New-Ini $sym $c $report | Set-Content $ini -Encoding ASCII
    Remove-Item (Join-Path $data "$report.htm") -EA SilentlyContinue
    $p=Start-Process $term -ArgumentList "/config:`"$ini`"" -PassThru
    $p.WaitForExit(400000)|Out-Null
    if(!$p.HasExited){ $p.Kill(); Start-Sleep 2 }
    $rep=Join-Path $data "$report.htm"; $t=0
    while(!(Test-Path $rep) -and $t -lt 30){ Start-Sleep -Milliseconds 500; $t++ }
    if(Test-Path $rep){
      $text=(Get-Content $rep -Raw -Encoding UTF8) -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' '
      $sN+=(TN (GS $text "Total Net Profit:")); $sT+=[int](TN (GS $text "Total Trades:"))
      $sGP+=(TN (GS $text "Gross Profit:")); $sGL+=(TN (GS $text "Gross Loss:"))
    }
  }
  $pf = if($sGL -ne 0){[math]::Round($sGP/[math]::Abs($sGL),2)}else{"n/a"}
  Write-Output ("{0,-14} AGG net={1,10:N2}  trades={2,-4} PF={3}" -f $c.id,$sN,$sT,$pf)
}
