@echo off
setlocal
cd /d %~dp0

echo ============================================================
echo Wise Trader - scoped git re-init (fixes the "repo root is
echo C:\Users\srika" problem)
echo ============================================================
echo.
echo This will:
echo   1. Remove the broken .git folder INSIDE THIS FOLDER ONLY
echo      (Wise Trader\.git - it has no objects store, so it holds
echo      no commits; safe to remove)
echo   2. git init a fresh repo scoped to Wise Trader
echo   3. Point it at the Wise-Expert remote
echo   4. Push to a NEW branch (not main/develop) so nothing on
echo      GitHub gets overwritten - you review/merge it yourself
echo.
echo It will NOT touch C:\Users\srika\.git or anything outside
echo this folder. If step 5's verification fails, the script stops
echo before adding or committing anything.
echo ============================================================
pause

if exist ".git" (
  echo Removing existing (broken) .git ...
  rmdir /s /q ".git"
)

echo.
echo --- git init ---
git init -b main
if errorlevel 1 (
  echo *** git init failed. ***
  goto :end
)

echo.
echo --- Safety check: confirm the repo root is THIS folder, not home ---
for /f "delims=" %%r in ('git rev-parse --show-toplevel') do set TOPLEVEL=%%r
echo Repo root reported as: %TOPLEVEL%
echo This folder is:        %CD%
if /i not "%TOPLEVEL%"=="%CD:\=/%" (
  echo *** MISMATCH - repo root is not this folder. Stopping. ***
  echo *** Do not proceed - tell Claude what TOPLEVEL printed above. ***
  goto :end
)
echo OK - repo is correctly scoped to Wise Trader only.

echo.
echo --- Remote ---
git remote add origin https://github.com/schundi365/Wise-Expert.git
git remote -v

echo.
echo --- .gitignore check ---
type .gitignore | findstr /C:"claude"

echo.
echo --- Files about to be staged (review carefully) ---
git add -A -n
echo.
set /p CONFIRM="Everything above look like ONLY Wise Trader files? (y/n): "
if /i not "%CONFIRM%"=="y" (
  echo Stopping - nothing staged.
  goto :end
)

git add -A

echo.
echo --- Double-check nothing Claude-related or credential-looking slipped through ---
git status --short | findstr /I "claude .env credential secret key token password" && (
  echo *** Suspicious file(s) staged - aborting. Check .gitignore. ***
  git reset
  goto :end
)

git commit -m "v2.43: per-symbol parameter overrides + multi-symbol regression campaign" -m "Re-initialized as its own scoped repo 2026-07-23 - the previous .git here was broken (no objects store) and git was silently falling through to a home-directory repo shared with unrelated projects." -m "- src/SymbolProfile.mqh: per-symbol tuned params, fixes InpProfileBin scale mismatch" -m "- tests/configs: S/E/G series ablations + tuned combos (GBPUSD, XAGUSD, EURUSD)" -m "- docs/*.xlsx: Feature Log Document Log sheet, Regression Matrix rebuilt per-symbol, Demo Tracker"

echo.
set /p BRANCHNAME="Push to which NEW branch name (e.g. sync-2026-07-23): "
if "%BRANCHNAME%"=="" set BRANCHNAME=sync-2026-07-23
git branch -M %BRANCHNAME%
git push -u origin %BRANCHNAME%
if errorlevel 1 (
  echo *** Push failed - see error above (auth, etc). ***
  goto :end
)

echo.
echo ============================================================
echo DONE - pushed to origin/%BRANCHNAME%
echo Open a PR on GitHub to merge into main/develop when ready -
echo this deliberately did NOT push straight to main.
echo ============================================================

:end
pause
