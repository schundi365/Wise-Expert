# MomentumScalper PORTFOLIO real-tick test across the full basket. Pepperstone.
# Also captures gross profit/loss + avg win/loss for root-cause cost analysis.
$ErrorActionPreference="Stop"
$term="C:\Users\srika\Trading\Pepperstone\terminal64.exe"
$data="C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\98B028FE55E86F6449ABBE8302BC7D42"
$iniDir="c:\Users\srika\Labs\AgenticAI\Expert Trader\Wise Trader\src\MomentumScalper\sweep"
if(!(Test-Path $iniDir)){ New-Item -ItemType Directory -Path $iniDir -Force | Out-Null }

$symbols=@("XAUUSD","XAGUSD","EURUSD","GBPUSD","EURGBP","GBPJPY","GBPCHF","USDCHF","USDJPY","USDX","XAUGBP")

function New-Ini($sym,$report){
@"
[Tester]
Expert=MomentumScalper\MomentumScalper.ex5
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
InpRewardRatio=1.8
InpDailyLossStop=60.0
InpMaxLot=1.00
InpMinLot=0.01
InpBreakoutBars=7
InpBufferPoints=10
InpEntryMode=0
InpEmaFast=21
InpEmaSlow=50
InpUseEmaFilter=false
InpAtrPeriod=14
InpAtrMinPips=4.0
InpAtrMaxPips=0.0
InpStopAtrMult=1.5
InpBeTriggerR=1.0
InpBeLockPips=1.0
InpTrailAtrMult=2.0
InpMaxSpreadPts=60
InpUseSession=false
InpAvoidRollover=true
InpRolloverHour=23
InpOneTradePerBar=true
InpMagic=77012024
InpSlippage=30
InpShowPanel=false
InpEnableLog=false
InpDebugSkips=false
"@
}
function GS($text,$l){ $m=[regex]::Match($text,[regex]::Escape($l)+"[^A-Za-z]{0,45}"); if($m.Success){return ($m.Value -replace [regex]::Escape($l),'').Trim()}; return "" }
function TN($s){ if($s -eq $null){return 0}; $x=($s -replace '[^\d\.\-]',''); if($x -eq '' -or $x -eq '-'){return 0}; return [double]$x }

$results=@(); $sN=0.0; $sT=0; $sGP=0.0; $sGL=0.0
foreach($sym in $symbols){
  $report="MS_bk_$sym"; $ini=Join-Path $iniDir "bk_$sym.ini"
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
    $gp=GS $text "Gross Profit:"; $gl=GS $text "Gross Loss:"
    $sN+=(TN $net); $sT+=[int](TN $tr); $sGP+=(TN $gp); $sGL+=(TN $gl)
    $results+=[pscustomobject]@{ Symbol=$sym; Net=$net; PF=$pf; Trades=$tr; GP=$gp; GL=$gl }
  } else { $results+=[pscustomobject]@{ Symbol=$sym; Net="NO REPORT"; PF="";Trades="";GP="";GL="" } }
}
$results | Format-Table -AutoSize | Out-String -Width 200
$aggPF = if($sGL -ne 0){ [math]::Round($sGP/[math]::Abs($sGL),2) } else { "n/a" }
Write-Output "==================== PORTFOLIO AGGREGATE (MomentumScalper, real ticks) ===================="
Write-Output ("  Basket net P/L : {0:N2}" -f $sN)
Write-Output ("  Total trades   : {0}" -f $sT)
Write-Output ("  Gross profit   : {0:N2}   Gross loss: {1:N2}" -f $sGP,$sGL)
Write-Output ("  Aggregate PF   : {0}" -f $aggPF)
if($sT -gt 0){ Write-Output ("  Avg trade P/L  : {0:N2}" -f ($sN/$sT)) }
