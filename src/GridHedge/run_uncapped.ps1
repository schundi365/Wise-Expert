# GridHedge UNCAPPED (true JNS behavior): book greens, let losers float FREELY.
# No floating-loss stop, no side SL, no equity stop, high level cap.
# Run 1: 6-month OHLC (Jan-Jul, best-case optimistic model).
# Run 2: 4-month real ticks (Mar-Jul, honest fills).
$ErrorActionPreference="Stop"
$term="C:\Users\srika\Trading\Vantage\terminal64.exe"
$data="C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\92518C9899A1ED3884F29F1749EEC361"
$iniDir="c:\Users\srika\Labs\AgenticAI\Expert Trader\Wise Trader\src\GridHedge\sweep"
if(!(Test-Path $iniDir)){ New-Item -ItemType Directory -Path $iniDir -Force | Out-Null }

# id, model(1=OHLC,4=realtick), from, to
$runs=@(
  @{id="6mo_ohlc";  model=1; from="2026.01.01"; to="2026.07.24"},
  @{id="4mo_ticks"; model=4; from="2026.03.20"; to="2026.07.24"}
)
function New-Ini($r,$report){
@"
[Tester]
Expert=GridHedge\GridHedge.ex5
Symbol=XAUUSD
Period=M5
Model=$($r.model)
Optimization=0
FromDate=$($r.from)
ToDate=$($r.to)
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
InpLot=0.10
InpGapPoints=500
InpTpMoney=6.0
InpLockMoney=50.0
InpTradeBuy=true
InpTradeSell=true
InpProtPoints=200
InpBSStepPoints=100
InpBeOffsetPoints=10
InpBuyTarget=0.0
InpSellTarget=0.0
InpKeepHedge=2
InpSideSL=0.0
InpScalpMode=true
InpScalpSlots=3
InpScalpGapPips=8.0
InpScalpMinSecs=5
InpMaxLevels=50
InpMaxFloatingLoss=0.0
InpEquityStopPct=0.0
InpBasketTP=0.0
InpCloseAllOnStop=false
InpMagic=26023332
InpSlippage=30
InpStartRunning=true
InpShowPanel=false
InpEnableLog=false
"@
}
function Get-Stat($text,$label){ $m=[regex]::Match($text,[regex]::Escape($label)+"[^A-Za-z]{0,45}"); if($m.Success){return ($m.Value -replace [regex]::Escape($label),'').Trim()}; return "" }
$results=@()
foreach($r in $runs){
  $report="GH_uncap_$($r.id)"; $iniPath=Join-Path $iniDir "uncap_$($r.id).ini"
  New-Ini $r $report | Set-Content $iniPath -Encoding ASCII
  Remove-Item (Join-Path $data "$report.htm") -ErrorAction SilentlyContinue
  $p=Start-Process $term -ArgumentList "/config:`"$iniPath`"" -PassThru
  $p.WaitForExit(600000)|Out-Null
  if(!$p.HasExited){ $p.Kill(); Start-Sleep 2 }
  $rep=Join-Path $data "$report.htm"; $tries=0
  while(!(Test-Path $rep) -and $tries -lt 40){ Start-Sleep -Milliseconds 500; $tries++ }
  if(Test-Path $rep){
    $html=Get-Content $rep -Raw -Encoding UTF8; $text=$html -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' '
    $results+=[pscustomobject]@{ Run=$r.id
      Net=(Get-Stat $text "Total Net Profit:"); PF=(Get-Stat $text "Profit Factor:"); Trades=(Get-Stat $text "Total Trades:")
      Won=(Get-Stat $text "Profit Trades (% of total):"); MaxDD=(Get-Stat $text "Balance Drawdown Maximal:")
      MaxEquityDD=(Get-Stat $text "Equity Drawdown Maximal:") }
  } else { $results+=[pscustomobject]@{ Run=$r.id; Net="NO REPORT"; PF="";Trades="";Won="";MaxDD="";MaxEquityDD="" } }
}
$results | Format-List | Out-String -Width 200
