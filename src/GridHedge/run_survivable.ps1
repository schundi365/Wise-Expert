# GridHedge "survivable" real-tick test: book greens + keep hedging, but HARD caps
# so a single trend cannot blow up. Honest test of the grid-hedging premise.
$ErrorActionPreference="Stop"
$term="C:\Users\srika\Trading\Vantage\terminal64.exe"
$data="C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\92518C9899A1ED3884F29F1749EEC361"
$iniDir="c:\Users\srika\Labs\AgenticAI\Expert Trader\Wise Trader\src\GridHedge\sweep"
if(!(Test-Path $iniDir)){ New-Item -ItemType Directory -Path $iniDir -Force | Out-Null }

# id, maxLevels, sideSL(£), maxFloatLoss(£)
$variants=@(
  @{id="tight";  lvl=4; sidesl=100; maxfl=200},
  @{id="mid";    lvl=6; sidesl=150; maxfl=300},
  @{id="loose";  lvl=8; sidesl=250; maxfl=500}
)
function New-Ini($v,$report){
@"
[Tester]
Expert=GridHedge\GridHedge.ex5
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
InpSideSL=$($v.sidesl)
InpScalpMode=true
InpScalpSlots=3
InpScalpGapPips=8.0
InpScalpMinSecs=5
InpMaxLevels=$($v.lvl)
InpMaxFloatingLoss=$($v.maxfl)
InpEquityStopPct=15.0
InpBasketTP=0.0
InpCloseAllOnStop=true
InpMagic=26023332
InpSlippage=30
InpStartRunning=true
InpShowPanel=false
InpEnableLog=false
"@
}
function Get-Stat($text,$label){ $m=[regex]::Match($text,[regex]::Escape($label)+"[^A-Za-z]{0,45}"); if($m.Success){return ($m.Value -replace [regex]::Escape($label),'').Trim()}; return "" }
$results=@()
foreach($v in $variants){
  $report="GH_surv_$($v.id)"; $iniPath=Join-Path $iniDir "$($v.id).ini"
  New-Ini $v $report | Set-Content $iniPath -Encoding ASCII
  Remove-Item (Join-Path $data "$report.htm") -ErrorAction SilentlyContinue
  $p=Start-Process $term -ArgumentList "/config:`"$iniPath`"" -PassThru
  $p.WaitForExit(300000)|Out-Null
  if(!$p.HasExited){ $p.Kill(); Start-Sleep 2 }
  $rep=Join-Path $data "$report.htm"; $tries=0
  while(!(Test-Path $rep) -and $tries -lt 30){ Start-Sleep -Milliseconds 500; $tries++ }
  if(Test-Path $rep){
    $html=Get-Content $rep -Raw -Encoding UTF8; $text=$html -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' '
    $results+=[pscustomobject]@{ ID=$v.id; MaxLvl=$v.lvl; SideSL=$v.sidesl; MaxFL=$v.maxfl
      Net=(Get-Stat $text "Total Net Profit:"); PF=(Get-Stat $text "Profit Factor:"); Trades=(Get-Stat $text "Total Trades:")
      Won=(Get-Stat $text "Profit Trades (% of total):"); MaxDD=(Get-Stat $text "Balance Drawdown Maximal:") }
  } else { $results+=[pscustomobject]@{ ID=$v.id; MaxLvl=$v.lvl; SideSL=$v.sidesl; MaxFL=$v.maxfl; Net="NO REPORT"; PF="";Trades="";Won="";MaxDD="" } }
}
$results | Format-Table -AutoSize | Out-String -Width 200
