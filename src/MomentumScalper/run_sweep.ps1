# MomentumScalper config sweep driver.
# Loops over variants, runs terminal64 headless for each, parses report stats.

$ErrorActionPreference = "Stop"
$term = "C:\Users\srika\Trading\Vantage\terminal64.exe"
$data = "C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\92518C9899A1ED3884F29F1749EEC361"
$iniDir = "c:\Users\srika\Labs\AgenticAI\Expert Trader\Wise Trader\src\MomentumScalper\sweep"
if(!(Test-Path $iniDir)){ New-Item -ItemType Directory -Path $iniDir -Force | Out-Null }

# variant: id, bars, gate, ema(true/false), oneperbar(true/false)
$variants = @(
  @{id="A"; bars=10; gate=4.0; ema="false"; opb="true"},
  @{id="B"; bars=7;  gate=4.0; ema="false"; opb="true"},
  @{id="C"; bars=14; gate=4.0; ema="false"; opb="true"},
  @{id="D"; bars=10; gate=3.0; ema="false"; opb="true"},
  @{id="E"; bars=10; gate=6.0; ema="false"; opb="true"},
  @{id="F"; bars=10; gate=4.0; ema="true";  opb="true"},
  @{id="G"; bars=7;  gate=3.0; ema="false"; opb="false"}
)

function New-Ini($v, $report) {
@"
[Tester]
Expert=MomentumScalper\MomentumScalper.ex5
Symbol=XAUUSD
Period=M5
Model=1
Optimization=0
FromDate=2026.01.01
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
  $report = "MScalp_sweep_$($v.id)"
  $iniPath = Join-Path $iniDir "$($v.id).ini"
  New-Ini $v $report | Set-Content $iniPath -Encoding ASCII

  # clean any prior report
  Remove-Item (Join-Path $data "$report.htm") -ErrorAction SilentlyContinue

  # run headless, wait for the process to exit (ShutdownTerminal=1 closes it)
  $p = Start-Process $term -ArgumentList "/config:`"$iniPath`"" -PassThru
  $p.WaitForExit(120000) | Out-Null
  if(!$p.HasExited){ $p.Kill(); Start-Sleep 2 }

  # give the FS a moment to flush the report
  $rep = Join-Path $data "$report.htm"
  $tries=0
  while(!(Test-Path $rep) -and $tries -lt 20){ Start-Sleep -Milliseconds 500; $tries++ }

  if(Test-Path $rep){
    $html = Get-Content $rep -Raw -Encoding UTF8
    $text = $html -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' '
    $results += [pscustomobject]@{
      ID      = $v.id
      Bars    = $v.bars
      Gate    = $v.gate
      EMA     = $v.ema
      OnePerBar = $v.opb
      Net     = (Get-Stat $text "Total Net Profit:")
      PF      = (Get-Stat $text "Profit Factor:")
      Trades  = (Get-Stat $text "Total Trades:")
      Payoff  = (Get-Stat $text "Expected Payoff:")
      Won     = (Get-Stat $text "Profit Trades (% of total):")
      MaxDD   = (Get-Stat $text "Balance Drawdown Maximal:")
    }
  } else {
    $results += [pscustomobject]@{ ID=$v.id; Bars=$v.bars; Gate=$v.gate; EMA=$v.ema; OnePerBar=$v.opb; Net="NO REPORT"; PF=""; Trades=""; Payoff=""; Won=""; MaxDD="" }
  }
}

$results | Format-Table -AutoSize | Out-String -Width 200 | Set-Content (Join-Path $iniDir "sweep_results.txt")
$results | Format-Table -AutoSize | Out-String -Width 200
