# MeanReversion config sweep. M5, Jan-Jul 2026, 1-min OHLC.
$ErrorActionPreference="Stop"
$term="C:\Users\srika\Trading\Vantage\terminal64.exe"
$data="C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\92518C9899A1ED3884F29F1749EEC361"
$iniDir="c:\Users\srika\Labs\AgenticAI\Expert Trader\Wise Trader\src\MeanReversion\sweep"
if(!(Test-Path $iniDir)){ New-Item -ItemType Directory -Path $iniDir -Force | Out-Null }

# id, rsiOB, rsiOS, adxMax, R, requireRsi
$variants=@(
  @{id="A"; ob=70; os=30; adx=30; R=1.0; rsi="true"},
  @{id="B"; ob=75; os=25; adx=30; R=1.0; rsi="true"},
  @{id="C"; ob=70; os=30; adx=25; R=1.0; rsi="true"},
  @{id="D"; ob=70; os=30; adx=30; R=1.5; rsi="true"},
  @{id="E"; ob=70; os=30; adx=40; R=1.0; rsi="true"},
  @{id="F"; ob=70; os=30; adx=30; R=1.0; rsi="false"}
)
function New-Ini($v,$report){
@"
[Tester]
Expert=MeanReversion\MeanReversion.ex5
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
InpRewardRatio=$($v.R)
InpDailyLossStop=60.0
InpMaxLot=1.00
InpMinLot=0.01
InpBbPeriod=20
InpBbDev=2.0
InpRsiPeriod=14
InpRsiOB=$($v.ob)
InpRsiOS=$($v.os)
InpRequireRsi=$($v.rsi)
InpUseTrendGuard=true
InpAdxPeriod=14
InpAdxMax=$($v.adx)
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
"@
}
function Get-Stat($text,$label){ $m=[regex]::Match($text,[regex]::Escape($label)+"[^A-Za-z]{0,45}"); if($m.Success){return ($m.Value -replace [regex]::Escape($label),'').Trim()}; return "" }

$results=@()
foreach($v in $variants){
  $report="MRev_sweep_$($v.id)"; $iniPath=Join-Path $iniDir "$($v.id).ini"
  New-Ini $v $report | Set-Content $iniPath -Encoding ASCII
  Remove-Item (Join-Path $data "$report.htm") -ErrorAction SilentlyContinue
  $p=Start-Process $term -ArgumentList "/config:`"$iniPath`"" -PassThru
  $p.WaitForExit(120000)|Out-Null
  if(!$p.HasExited){ $p.Kill(); Start-Sleep 2 }
  $rep=Join-Path $data "$report.htm"; $tries=0
  while(!(Test-Path $rep) -and $tries -lt 20){ Start-Sleep -Milliseconds 500; $tries++ }
  if(Test-Path $rep){
    $html=Get-Content $rep -Raw -Encoding UTF8; $text=$html -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' '
    $results+=[pscustomobject]@{ ID=$v.id; OB=$v.ob; OS=$v.os; ADX=$v.adx; R=$v.R; ReqRSI=$v.rsi
      Net=(Get-Stat $text "Total Net Profit:"); PF=(Get-Stat $text "Profit Factor:"); Trades=(Get-Stat $text "Total Trades:")
      Won=(Get-Stat $text "Profit Trades (% of total):"); MaxDD=(Get-Stat $text "Balance Drawdown Maximal:") }
  } else { $results+=[pscustomobject]@{ ID=$v.id; OB=$v.ob; OS=$v.os; ADX=$v.adx; R=$v.R; ReqRSI=$v.rsi; Net="NO REPORT"; PF="";Trades="";Won="";MaxDD="" } }
}
$results | Format-Table -AutoSize | Out-String -Width 200
