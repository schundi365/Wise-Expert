@echo off
setlocal
REM ================================================================
REM  Wise-Expert: one-time restructure to CI/CD layout + publish to
REM  https://github.com/schundi365/Wise-Expert.git
REM  Run on Sri's PC by double-clicking. Requires Git for Windows.
REM  Safe to re-run: every move is guarded by an existence check.
REM ================================================================
cd /d "%~dp0"

where git >nul 2>nul || (echo Git not installed - https://git-scm.com & pause & exit /b 1)

echo === 1/4  Restructuring folders ===
if exist "MQL5\Experts\WiseTrader" (
  if not exist "src" mkdir src
  move "MQL5\Experts\WiseTrader" "src\WiseTrader" >nul
)
if exist "MQL5\Experts\WiseTraderORB" move "MQL5\Experts\WiseTraderORB" "src\WiseTraderORB" >nul
if exist "MQL5" rmdir /s /q "MQL5"

if exist "Console" (
  if not exist "tools" mkdir tools
  move "Console" "tools\console" >nul
)

if not exist "tests\configs" mkdir "tests\configs"
if not exist "results" mkdir "results"
if not exist "docs" mkdir "docs"

if exist "Tester Sets" (
  move "Tester Sets\*.set" "tests\configs\" >nul 2>nul
  move "Tester Sets\report_*.htm*" "results\" >nul 2>nul
  move "Tester Sets\regression_results.csv" "results\" >nul 2>nul
  move "Tester Sets\campaign_status.json" "results\" >nul 2>nul
  if exist "Tester Sets\journals" move "Tester Sets\journals" "results\journals" >nul
  move "Tester Sets\*.xlsx" "docs\" >nul 2>nul
  rmdir /s /q "Tester Sets" 2>nul
)
move "*.docx" "docs\" >nul 2>nul
move "WiseTrader_Feature_Log.xlsx" "docs\" >nul 2>nul

echo === 2/4  Git repository ===
if exist ".git\config.lock" del /f ".git\config.lock"
if not exist ".git\HEAD" git init -b main
git config user.name "Sri"
git config user.email "vishnukanth1@gmail.com"

echo === 3/4  Commit ===
git add -A
git commit -m "Wise-Expert v2.20: CI/CD layout (src/ tools/ tests/ results/ docs/), CI validation, branch model"

echo === 4/4  Publish ===
git remote remove origin 2>nul
git remote add origin https://github.com/schundi365/Wise-Expert.git
git push -u origin main
git branch develop 2>nul
git push -u origin develop

echo.
echo ================================================================
echo  Done. On github.com finish org hygiene (cannot be scripted):
echo   - Settings - Branches: protect 'main' (require PR + CI green)
echo   - Fine-grained token for the remote tester: THIS repo only,
echo     Contents: Read and write
echo  Remote tester pushes campaigns to branches named results/DATE.
echo ================================================================
pause
