# SwingTrader H1 sweep on the PEPPERSTONE terminal (separate instance from the
# Vantage demo that's live). Jan-Jul 2026, 1-min OHLC.
$ErrorActionPreference="Stop"
$term="C:\Users\srika\Trading\Pepperstone\terminal64.exe"
$data="C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\98B028FE55E86F6449ABBE8302BC7D42"
$iniDir="c:\Users\srika\Labs\AgenticAI\Expert Trader\Wise Trader\src\SwingTrader\sweep"
if(!(Test-Path $iniDir)){ New-Item -ItemType Directory -Path $iniDir -Force | Out-Null }

$variants=@(
  @{id="A_h1"; tf="H1"; don=20; R=2.0; slope="true"},
  @{id="B_h1"; tf="H1"; don=10; R=2.0; slope="true"},
  @{id="C_h1"; tf="H1"; don=20; R=1.5; slope="true"},
  @{id="D_h1"; tf="H1"; don=20; R=3.0; slope="true"},
  @{id="E_h1"; tf="H1"; don=20; R=2.0; slope="false"},
  @{id="F_h4"; tf="H4"; don=20; R=2.0; slope="true"}
)
function New-Ini($v,$report){
@"
[Tester]
Expert=SwingTrader\SwingTrader.ex5
Symbol=XAUUSD
Period=$($v.tf)
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
InpDailyLossStop=100.0
InpMaxLot=1.00
InpMinLot=0.01
InpDonchianBars=$($v.don)
InpBufferPoints=30
InpEmaFast=50
InpEmaSlow=200
InpUseEmaStack=true
InpUseEmaSlope=$($v.slope)
InpAtrPeriod=14
InpAtrMinPips=0.0
InpStopAtrMult=2.0
InpBeTriggerR=1.0
InpBeLockPips=2.0
InpTrailAtrMult=3.0
InpMaxSpreadPts=80
InpAvoidRollover=true
InpRolloverHour=23
InpMaxPositions=1
InpMagic=77032024
InpSlippage=40
InpShowPanel=false
InpEnableLog=false
InpDebugSkips=false
"@
}
function Get-Stat($text,$label){ $m=[regex]::Match($text,[regex]::Escape($label)+"[^A-Za-z]{0,45}"); if($m.Success){return ($m.Value -replace [regex]::Escape($label),'').Trim()}; return "" }
$results=@()
foreach($v in $variants){
  $report="Swing_$($v.id)"; $iniPath=Join-Path $iniDir "pep_$($v.id).ini"
  New-Ini $v $report | Set-Content $iniPath -Encoding ASCII
  Remove-Item (Join-Path $data "$report.htm") -ErrorAction SilentlyContinue
  $p=Start-Process $term -ArgumentList "/config:`"$iniPath`"" -PassThru
  $p.WaitForExit(180000)|Out-Null
  if(!$p.HasExited){ $p.Kill(); Start-Sleep 2 }
  $rep=Join-Path $data "$report.htm"; $tries=0
  while(!(Test-Path $rep) -and $tries -lt 20){ Start-Sleep -Milliseconds 500; $tries++ }
  if(Test-Path $rep){
    $html=Get-Content $rep -Raw -Encoding UTF8; $text=$html -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' '
    $results+=[pscustomobject]@{ ID=$v.id; TF=$v.tf; Don=$v.don; R=$v.R; Slope=$v.slope
      Net=(Get-Stat $text "Total Net Profit:"); PF=(Get-Stat $text "Profit Factor:"); Trades=(Get-Stat $text "Total Trades:")
      Won=(Get-Stat $text "Profit Trades (% of total):"); MaxDD=(Get-Stat $text "Balance Drawdown Maximal:") }
  } else { $results+=[pscustomobject]@{ ID=$v.id; TF=$v.tf; Don=$v.don; R=$v.R; Slope=$v.slope; Net="NO REPORT"; PF="";Trades="";Won="";MaxDD="" } }
}
$results | Format-Table -AutoSize | Out-String -Width 200
