@echo off
setlocal
cd /d %~dp0

echo ============================================================
echo Wise Trader - commit and push
echo ============================================================

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 (
  echo *** Not a git repo here, or git can't read it. ***
  echo If this is the first push, run setup_git.bat first.
  goto :end
)

echo.
echo --- .gitignore check (should list .claude/, CLAUDE.md, etc.) ---
type .gitignore | findstr /C:"claude"
echo.

echo --- Remote check ---
git remote -v
if errorlevel 1 (
  echo *** No remote configured. Adding origin... ***
  git remote add origin https://github.com/schundi365/Wise-Expert.git
)

echo.
echo --- Files about to be staged (review before continuing) ---
git add -A -n
echo.
set /p CONFIRM="Proceed with staging + commit? (y/n): "
if /i not "%CONFIRM%"=="y" goto :end

git add -A

echo.
echo --- Double-check nothing Claude-related slipped through ---
git status --short | findstr /I "claude" && (
  echo *** Claude-related file(s) staged - aborting, check .gitignore. ***
  git reset
  goto :end
)

git commit -m "v2.43: per-symbol parameter overrides + multi-symbol regression campaign (GBPUSD/XAGUSD/EURUSD)" -m "- src/SymbolProfile.mqh: per-symbol tuned params applied in OnInit, fixes InpProfileBin scale mismatch" -m "- 22 new tests/configs/*.set (S/E/G series ablations + tuned combos)" -m "- docs/WiseTrader_Feature_Log.xlsx: Document Log sheet, F46-F51 candidates" -m "- docs/WiseTrader_Regression_Matrix.xlsx: rebuilt per-symbol from regression_history.csv" -m "- docs/WiseTrader_Demo_Tracker.xlsx: 4-week demo forward-test log" -m "- CHANGELOG.md: v2.41 (version-string log fix), v2.42 (A2_tuned baked into defaults), v2.43 (per-symbol overrides)"

if errorlevel 1 (
  echo *** Commit failed - nothing to commit, or an error above. ***
  goto :end
)

echo.
git branch --show-current
set /p BRANCH="Push to which branch (blank = current)? "
if "%BRANCH%"=="" (
  for /f %%b in ('git branch --show-current') do set BRANCH=%%b
)

git push origin %BRANCH%
if errorlevel 1 (
  echo *** Push failed - check the error above (auth, no upstream, etc). ***
  echo If this is the first push: git push -u origin %BRANCH%
  goto :end
)

echo.
echo ============================================================
echo DONE - pushed to origin/%BRANCH%
echo ============================================================

:end
pause
