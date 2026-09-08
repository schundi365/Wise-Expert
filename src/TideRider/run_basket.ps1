# TideRider PORTFOLIO real-tick test across a basket (idea 1). Pepperstone.
# Each symbol run real-tick (Model=4) H1 Mar20-Jul24; results aggregated.
# The verdict is the SUM across the basket, not any single symbol.
$ErrorActionPreference="Stop"
$term="C:\Users\srika\Trading\Pepperstone\terminal64.exe"
$data="C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\98B028FE55E86F6449ABBE8302BC7D42"
$iniDir="c:\Users\srika\Labs\AgenticAI\Expert Trader\Wise Trader\src\TideRider\sweep"
if(!(Test-Path $iniDir)){ New-Item -ItemType Directory -Path $iniDir -Force | Out-Null }

# basket: symbols with both tick data and H1 history on this terminal
$symbols=@("XAUUSD","XAGUSD","EURUSD","GBPUSD","USDCHF","USDJPY","XAUGBP","USDX")

function New-Ini($sym,$report){
@"
[Tester]
Expert=TideRider\TideRider.ex5
Symbol=$sym
Period=H1
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
InpDailyLossStop=150.0
InpMaxLot=2.00
InpMinLot=0.01
InpDonchianBars=20
InpBufferPoints=30
InpEmaFast=50
InpEmaSlow=200
InpUseEmaStack=true
InpUseEmaSlope=true
InpAtrPeriod=14
InpStopAtrMult=2.0
InpTrailAtrMult=4.0
InpBeTriggerR=1.0
InpPyramid=true
InpAddStepR=1.0
InpMaxAdds=3
InpAddRiskFrac=1.0
InpMaxSpreadPts=100
InpAvoidRollover=true
InpRolloverHour=23
InpMagic=77042024
InpSlippage=40
InpShowPanel=false
InpEnableLog=false
"@
}
function GS($text,$l){ $m=[regex]::Match($text,[regex]::Escape($l)+"[^A-Za-z]{0,45}"); if($m.Success){return ($m.Value -replace [regex]::Escape($l),'').Trim()}; return "" }
function ToNum($s){ if($s -eq $null){return 0}; $x=($s -replace '[^\d\.\-]',''); if($x -eq '' -or $x -eq '-'){return 0}; return [double]$x }

$results=@(); $sumNet=0.0; $sumTrades=0; $sumGP=0.0; $sumGL=0.0
foreach($sym in $symbols){
  $report="Tide_$sym"; $ini=Join-Path $iniDir "$sym.ini"
  New-Ini $sym $report | Set-Content $ini -Encoding ASCII
  Remove-Item (Join-Path $data "$report.htm") -EA SilentlyContinue
  $p=Start-Process $term -ArgumentList "/config:`"$ini`"" -PassThru
  $p.WaitForExit(400000)|Out-Null
  if(!$p.HasExited){ $p.Kill(); Start-Sleep 2 }
  $rep=Join-Path $data "$report.htm"; $t=0
  while(!(Test-Path $rep) -and $t -lt 30){ Start-Sleep -Milliseconds 500; $t++ }
  if(Test-Path $rep){
    $text=(Get-Content $rep -Raw -Encoding UTF8) -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' '
    $net=GS $text "Total Net Profit:"; $tr=GS $text "Total Trades:"; $pf=GS $text "Profit Factor:"
    $gp=GS $text "Gross Profit:"; $gl=GS $text "Gross Loss:"; $dd=GS $text "Balance Drawdown Maximal:"
    $sumNet+=(ToNum $net); $sumTrades+=[int](ToNum $tr); $sumGP+=(ToNum $gp); $sumGL+=(ToNum $gl)
    $results+=[pscustomobject]@{ Symbol=$sym; Net=$net; PF=$pf; Trades=$tr; MaxDD=$dd }
  } else { $results+=[pscustomobject]@{ Symbol=$sym; Net="NO REPORT"; PF="";Trades="";MaxDD="" } }
}
$results | Format-Table -AutoSize | Out-String -Width 200
$aggPF = if($sumGL -ne 0){ [math]::Round($sumGP/[math]::Abs($sumGL),2) } else { "n/a" }
Write-Output "==================== PORTFOLIO AGGREGATE (real ticks) ===================="
Write-Output ("  Basket net P/L : {0:N2}" -f $sumNet)
Write-Output ("  Total trades   : {0}" -f $sumTrades)
Write-Output ("  Gross profit   : {0:N2}   Gross loss: {1:N2}" -f $sumGP,$sumGL)
Write-Output ("  Aggregate PF   : {0}" -f $aggPF)
