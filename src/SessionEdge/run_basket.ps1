# SessionEdge (ORB) real-tick basket test on Pepperstone. Mar20-Jul24.
# Tests 2 session hours across the basket; aggregates per session hour.
$ErrorActionPreference="Stop"
$term="C:\Users\srika\Trading\Pepperstone\terminal64.exe"
$data="C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\98B028FE55E86F6449ABBE8302BC7D42"
$iniDir="c:\Users\srika\Labs\AgenticAI\Expert Trader\Wise Trader\src\SessionEdge\sweep"
if(!(Test-Path $iniDir)){ New-Item -ItemType Directory -Path $iniDir -Force | Out-Null }

$symbols=@("XAUUSD","XAGUSD","EURUSD","GBPUSD","GBPJPY","USDCHF","USDJPY")
$sessions=@(7,13)   # London-ish open, NY-ish open (server time)

function New-Ini($sym,$hour,$report){
@"
[Tester]
Expert=SessionEdge\SessionEdge.ex5
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
InpRewardRatio=1.5
InpMaxLot=1.00
InpMinLot=0.01
InpSessionHour=$hour
InpRangeMins=60
InpFlatHour=20
InpBufferPoints=20
InpOneTradePerDay=true
InpStopFromRange=true
InpAtrPeriod=14
InpStopAtrMult=1.5
InpBeTriggerR=1.0
InpMaxSpreadPts=60
InpAvoidRollover=true
InpRolloverHour=23
InpMagic=77052024
InpSlippage=40
InpShowPanel=false
InpEnableLog=false
"@
}
function GS($text,$l){ $m=[regex]::Match($text,[regex]::Escape($l)+"[^A-Za-z]{0,45}"); if($m.Success){return ($m.Value -replace [regex]::Escape($l),'').Trim()}; return "" }
function TN($s){ $x=($s -replace '[^\d\.\-]',''); if($x -eq '' -or $x -eq '-'){return 0}; return [double]$x }

foreach($hour in $sessions){
  $sN=0.0;$sT=0;$sGP=0.0;$sGL=0.0;$rows=@()
  foreach($sym in $symbols){
    $report="ORB_${sym}_h$hour"; $ini=Join-Path $iniDir "${sym}_h$hour.ini"
    New-Ini $sym $hour $report | Set-Content $ini -Encoding ASCII
    Remove-Item (Join-Path $data "$report.htm") -EA SilentlyContinue
    $p=Start-Process $term -ArgumentList "/config:`"$ini`"" -PassThru
    $p.WaitForExit(400000)|Out-Null
    if(!$p.HasExited){ $p.Kill(); Start-Sleep 2 }
    $rep=Join-Path $data "$report.htm"; $t=0
    while(!(Test-Path $rep) -and $t -lt 30){ Start-Sleep -Milliseconds 500; $t++ }
    if(Test-Path $rep){
      $text=(Get-Content $rep -Raw -Encoding UTF8) -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' '
      $net=GS $text "Total Net Profit:"; $tr=GS $text "Total Trades:"; $pf=GS $text "Profit Factor:"
      $sN+=(TN $net);$sT+=[int](TN $tr);$sGP+=(TN (GS $text "Gross Profit:"));$sGL+=(TN (GS $text "Gross Loss:"))
      $rows+=("  {0,-8} Net={1,-9} PF={2,-5} Tr={3}" -f $sym,$net,$pf,$tr)
    } else { $rows+=("  {0,-8} (0 trades)" -f $sym) }
  }
  $pf = if($sGL -ne 0){[math]::Round($sGP/[math]::Abs($sGL),2)}else{"n/a"}
  Write-Output ("===== SESSION HOUR {0}:00 =====" -f $hour)
  $rows | ForEach-Object { Write-Output $_ }
  Write-Output ("  AGG net={0:N2}  trades={1}  PF={2}" -f $sN,$sT,$pf)
  Write-Output ""
}
