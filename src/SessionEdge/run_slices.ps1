# SessionEdge TEMPORAL robustness: run the best config (h7, range60, R1.0) real-tick
# across separate monthly slices of Mar20-Jul24, per the 4 positive symbols, and
# aggregate PER SLICE. Consistent positivity month-to-month = trust; one carrying
# slice = fragile / lucky stretch.
$ErrorActionPreference="Stop"
$term="C:\Users\srika\Trading\Pepperstone\terminal64.exe"
$data="C:\Users\srika\AppData\Roaming\MetaQuotes\Terminal\98B028FE55E86F6449ABBE8302BC7D42"
$iniDir="c:\Users\srika\Labs\AgenticAI\Expert Trader\Wise Trader\src\SessionEdge\slices"
if(!(Test-Path $iniDir)){ New-Item -ItemType Directory -Path $iniDir -Force | Out-Null }

$symbols=@("XAUUSD","XAGUSD","GBPUSD","USDCHF")
$slices=@(
  @{id="Apr"; from="2026.03.20"; to="2026.04.20"},
  @{id="May"; from="2026.04.20"; to="2026.05.20"},
  @{id="Jun"; from="2026.05.20"; to="2026.06.20"},
  @{id="Jul"; from="2026.06.20"; to="2026.07.24"}
)
function New-Ini($sym,$s,$report){
@"
[Tester]
Expert=SessionEdge\SessionEdge.ex5
Symbol=$sym
Period=M5
Model=4
Optimization=0
FromDate=$($s.from)
ToDate=$($s.to)
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
InpMaxLot=1.00
InpMinLot=0.01
InpSessionHour=7
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

foreach($s in $slices){
  $sN=0.0;$sT=0;$sGP=0.0;$sGL=0.0
  foreach($sym in $symbols){
    $report="ORBs_${sym}_$($s.id)"; $ini=Join-Path $iniDir "${sym}_$($s.id).ini"
    New-Ini $sym $s $report | Set-Content $ini -Encoding ASCII
    Remove-Item (Join-Path $data "$report.htm") -EA SilentlyContinue
    $p=Start-Process $term -ArgumentList "/config:`"$ini`"" -PassThru
    $p.WaitForExit(400000)|Out-Null
    if(!$p.HasExited){ $p.Kill(); Start-Sleep 2 }
    $rep=Join-Path $data "$report.htm"; $t=0
    while(!(Test-Path $rep) -and $t -lt 30){ Start-Sleep -Milliseconds 500; $t++ }
    if(Test-Path $rep){
      $text=(Get-Content $rep -Raw -Encoding UTF8) -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' '
      $sN+=(TN (GS $text "Total Net Profit:")); $sT+=[int](TN (GS $text "Total Trades:"))
      $sGP+=(TN (GS $text "Gross Profit:")); $sGL+=(TN (GS $text "Gross Loss:"))
    }
  }
  $pf = if($sGL -ne 0){[math]::Round($sGP/[math]::Abs($sGL),2)}else{"n/a"}
  Write-Output ("SLICE {0}  net={1,9:N2}  trades={2,-4} PF={3}" -f $s.id,$sN,$sT,$pf)
}
