# Real-tick verification of the top configs (B and C). Model=4 = every tick based on real ticks.
$ErrorActionPreference = "Stop"
$term = "C:\Users\srika\Trading\Vantage\terminal64.exe"
$data = "C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\92518C9899A1ED3884F29F1749EEC361"
$iniDir = "c:\Users\srika\Labs\AgenticAI\Expert Trader\Wise Trader\src\MomentumScalper\sweep"

# top two from the OHLC sweep
$variants = @(
  @{id="B_rt"; bars=7;  gate=4.0; ema="false"; opb="true"},
  @{id="C_rt"; bars=14; gate=4.0; ema="false"; opb="true"}
)

function New-Ini($v, $report) {
@"
[Tester]
Expert=MomentumScalper\MomentumScalper.ex5
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
InpRewardRatio=1.8
InpDailyLossStop=60.0
InpMaxLot=1.00
InpMinLot=0.01
InpBreakoutBars=$($v.bars)
InpBufferPoints=10
InpEmaFast=21
InpEmaSlow=50
InpUseEmaFilter=$($v.ema)
InpAtrPeriod=14
InpAtrMinPips=$($v.gate)
InpAtrMaxPips=0.0
InpStopAtrMult=1.5
InpBeTriggerR=1.0
InpBeLockPips=1.0
InpTrailAtrMult=2.0
InpMaxSpreadPts=60
InpUseSession=false
InpSessStartHour=7
InpSessEndHour=20
InpOneTradePerBar=$($v.opb)
InpMagic=77012024
InpSlippage=30
InpShowPanel=false
InpEnableLog=false
"@
}

function Get-Stat($text, $label) {
  $m = [regex]::Match($text, [regex]::Escape($label) + "[^A-Za-z]{0,45}")
  if($m.Success){ return ($m.Value -replace [regex]::Escape($label),'').Trim() }
  return ""
}

$results = @()
foreach($v in $variants){
  $report = "MScalp_$($v.id)"
  $iniPath = Join-Path $iniDir "$($v.id).ini"
  New-Ini $v $report | Set-Content $iniPath -Encoding ASCII
  Remove-Item (Join-Path $data "$report.htm") -ErrorAction SilentlyContinue

  $p = Start-Process $term -ArgumentList "/config:`"$iniPath`"" -PassThru
  $p.WaitForExit(300000) | Out-Null
  if(!$p.HasExited){ $p.Kill(); Start-Sleep 2 }

  $rep = Join-Path $data "$report.htm"
  $tries=0
  while(!(Test-Path $rep) -and $tries -lt 30){ Start-Sleep -Milliseconds 500; $tries++ }

  if(Test-Path $rep){
    $html = Get-Content $rep -Raw -Encoding UTF8
    $text = $html -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' '
    $results += [pscustomobject]@{
      ID=$v.id; Bars=$v.bars
      Net=(Get-Stat $text "Total Net Profit:")
      PF=(Get-Stat $text "Profit Factor:")
      Trades=(Get-Stat $text "Total Trades:")
      Payoff=(Get-Stat $text "Expected Payoff:")
      Won=(Get-Stat $text "Profit Trades (% of total):")
      MaxDD=(Get-Stat $text "Balance Drawdown Maximal:")
    }
  } else {
    $results += [pscustomobject]@{ ID=$v.id; Bars=$v.bars; Net="NO REPORT"; PF="";Trades="";Payoff="";Won="";MaxDD="" }
  }
}
$results | Format-Table -AutoSize | Out-String -Width 200
