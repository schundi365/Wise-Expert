# Diagnostic: config D on OHLC over the SAME Mar20-Jul24 window as the real-tick run.
# If ~0 trades here too, it confirms the 7 sweep trades were mostly PRE-Mar20
# (i.e. outside the tick-verifiable window) - meaning the edge is unverified.
$ErrorActionPreference="Stop"
$term="C:\Users\srika\Trading\Pepperstone\terminal64.exe"
$data="C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\98B028FE55E86F6449ABBE8302BC7D42"
$iniDir="c:\Users\srika\Labs\AgenticAI\Expert Trader\Wise Trader\src\SwingTrader\sweep"
$report="Swing_D_marwin"
$ini=Join-Path $iniDir "D_marwin.ini"
@"
[Tester]
Expert=SwingTrader\SwingTrader.ex5
Symbol=XAUUSD
Period=H1
Model=1
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
InpRewardRatio=3.0
InpDailyLossStop=100.0
InpDonchianBars=20
InpBufferPoints=30
InpEmaFast=50
InpEmaSlow=200
InpUseEmaStack=true
InpUseEmaSlope=true
InpAtrPeriod=14
InpStopAtrMult=2.0
InpBeTriggerR=1.0
InpBeLockPips=2.0
InpTrailAtrMult=3.0
InpMaxSpreadPts=80
InpMaxPositions=1
InpMagic=77032024
InpShowPanel=false
InpEnableLog=false
"@ | Set-Content $ini -Encoding ASCII
Remove-Item (Join-Path $data "$report.htm") -EA SilentlyContinue
$p=Start-Process $term -ArgumentList "/config:`"$ini`"" -PassThru
$p.WaitForExit(180000)|Out-Null
if(!$p.HasExited){ $p.Kill() }
$rep=Join-Path $data "$report.htm"; $t=0
while(!(Test-Path $rep) -and $t -lt 20){ Start-Sleep -Milliseconds 500; $t++ }
function GS($text,$l){ $m=[regex]::Match($text,[regex]::Escape($l)+"[^A-Za-z]{0,45}"); if($m.Success){return ($m.Value -replace [regex]::Escape($l),'').Trim()}; return "" }
if(Test-Path $rep){ $text=(Get-Content $rep -Raw -Encoding UTF8) -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' '; Write-Output ("Mar20-Jul24 OHLC:  Net="+(GS $text "Total Net Profit:")+"  Trades="+(GS $text "Total Trades:")+"  PF="+(GS $text "Profit Factor:")) } else { Write-Output "NO REPORT" }
