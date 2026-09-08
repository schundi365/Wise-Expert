# Real-tick verification of MeanReversion config A. Model=4, Mar20-Jul24 2026.
$ErrorActionPreference="Stop"
$term="C:\Users\srika\Trading\Vantage\terminal64.exe"
$data="C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\92518C9899A1ED3884F29F1749EEC361"
$iniDir="c:\Users\srika\Labs\AgenticAI\Expert Trader\Wise Trader\src\MeanReversion\sweep"
$report="MRev_A_rt"
$iniPath=Join-Path $iniDir "A_rt.ini"

@"
[Tester]
Expert=MeanReversion\MeanReversion.ex5
Symbol=XAUUSD
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
InpRewardRatio=1.0
InpDailyLossStop=60.0
InpMaxLot=1.00
InpMinLot=0.01
InpBbPeriod=20
InpBbDev=2.0
InpRsiPeriod=14
InpRsiOB=70
InpRsiOS=30
InpRequireRsi=true
InpUseTrendGuard=true
InpAdxPeriod=14
InpAdxMax=30
InpAtrPeriod=14
InpAtrMinPips=4.0
InpStopAtrMult=1.5
InpBeTriggerR=1.0
InpBeLockPips=1.0
InpTrailAtrMult=0.0
InpMaxSpreadPts=60
InpAvoidRollover=true
InpRolloverHour=23
InpOneTradePerBar=true
InpMagic=77022024
InpSlippage=30
InpShowPanel=false
InpEnableLog=false
InpDebugSkips=false
"@ | Set-Content $iniPath -Encoding ASCII

Remove-Item (Join-Path $data "$report.htm") -ErrorAction SilentlyContinue
$p=Start-Process $term -ArgumentList "/config:`"$iniPath`"" -PassThru
$p.WaitForExit(300000)|Out-Null
if(!$p.HasExited){ $p.Kill(); Start-Sleep 2 }
$rep=Join-Path $data "$report.htm"; $tries=0
while(!(Test-Path $rep) -and $tries -lt 30){ Start-Sleep -Milliseconds 500; $tries++ }

function Get-Stat($text,$label){ $m=[regex]::Match($text,[regex]::Escape($label)+"[^A-Za-z]{0,45}"); if($m.Success){return ($m.Value -replace [regex]::Escape($label),'').Trim()}; return "" }
if(Test-Path $rep){
  $html=Get-Content $rep -Raw -Encoding UTF8; $text=$html -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' '
  [pscustomobject]@{
    Net=(Get-Stat $text "Total Net Profit:"); PF=(Get-Stat $text "Profit Factor:"); Trades=(Get-Stat $text "Total Trades:")
    Payoff=(Get-Stat $text "Expected Payoff:"); Won=(Get-Stat $text "Profit Trades (% of total):"); MaxDD=(Get-Stat $text "Balance Drawdown Maximal:")
  } | Format-List
} else { Write-Output "NO REPORT" }
