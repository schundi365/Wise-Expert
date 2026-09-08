# GridHedgeAVS real-tick test on Pepperstone. XAUUSD M5 Mar20-Jul24.
# Two configs to isolate the AVS effect:
#   surv   = safety caps ON (compare vs plain grid survivable -£1500)
#   uncap  = no caps, free float (compare vs plain grid -£10k wipeout)
$ErrorActionPreference="Stop"
$term="C:\Users\srika\Trading\Pepperstone\terminal64.exe"
$data="C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\98B028FE55E86F6449ABBE8302BC7D42"
$iniDir="c:\Users\srika\Labs\AgenticAI\Expert Trader\Wise Trader\src\GridHedge\sweep"
if(!(Test-Path $iniDir)){ New-Item -ItemType Directory -Path $iniDir -Force | Out-Null }

# id, maxLevels, sideSL, maxFloatLoss, eqStop
$variants=@(
  @{id="surv";  lvl=6; sidesl=150; maxfl=300; eq=15.0},
  @{id="uncap"; lvl=50; sidesl=0;  maxfl=0;   eq=0.0}
)
function New-Ini($v,$report){
@"
[Tester]
Expert=GridHedgeAVS\GridHedgeAVS.ex5
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
InpEquityStopPct=$($v.eq)
InpBasketTP=0.0
InpCloseAllOnStop=true
InpEnableAVS=true
InpATRTimeframe=5
InpATRPeriod=14
InpBaseATR=150.0
InpCounterTrendMult=0.5
InpWithTrendMult=1.5
InpMagic=26023332
InpSlippage=30
InpStartRunning=true
InpShowPanel=false
InpEnableLog=false
"@
}
function GS($text,$l){ $m=[regex]::Match($text,[regex]::Escape($l)+"[^A-Za-z]{0,45}"); if($m.Success){return ($m.Value -replace [regex]::Escape($l),'').Trim()}; return "" }
$results=@()
foreach($v in $variants){
  $report="GHAVS_$($v.id)"; $ini=Join-Path $iniDir "avs_$($v.id).ini"
  New-Ini $v $report | Set-Content $ini -Encoding ASCII
  Remove-Item (Join-Path $data "$report.htm") -EA SilentlyContinue
  $p=Start-Process $term -ArgumentList "/config:`"$ini`"" -PassThru
  $p.WaitForExit(400000)|Out-Null
  if(!$p.HasExited){ $p.Kill(); Start-Sleep 2 }
  $rep=Join-Path $data "$report.htm"; $t=0
  while(!(Test-Path $rep) -and $t -lt 30){ Start-Sleep -Milliseconds 500; $t++ }
  if(Test-Path $rep){
    $text=(Get-Content $rep -Raw -Encoding UTF8) -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' '
    $results+=[pscustomobject]@{ Config=$v.id
      Net=(GS $text "Total Net Profit:"); PF=(GS $text "Profit Factor:"); Trades=(GS $text "Total Trades:")
      Won=(GS $text "Profit Trades (% of total):"); MaxDD=(GS $text "Balance Drawdown Maximal:"); EqDD=(GS $text "Equity Drawdown Maximal:") }
  } else { $results+=[pscustomobject]@{ Config=$v.id; Net="NO REPORT"; PF="";Trades="";Won="";MaxDD="";EqDD="" } }
}
$results | Format-List | Out-String -Width 200
