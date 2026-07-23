@echo off
setlocal enabledelayedexpansion
cd /d %~dp0

echo ============================================================
echo WiseTrader multi-symbol regression campaign (v2.43)
echo.
echo ROUND 2 (run first - 3 configs): confirmation configs built
echo from the Round 1 ablation results below.
echo ROUND 1 (already completed 2026-07-20/21/22, kept here so this
echo script is safe to re-run from scratch on a fresh machine):
echo   GBPUSD 7 configs, XAGUSD 5 configs, EURUSD 6 configs
echo.
echo Past runs of a single model-1 config have taken anywhere from
echo ~1 hour to ~4 hours depending on symbol and whether the price
echo history cache was already warm.
echo.
echo BEFORE YOU START: close MetaTrader 5 completely (system tray too).
echo If a group fails immediately (compile error, or "terminal64 is
echo RUNNING"), the script stops there. Fix it and re-run - safe to
echo re-run, each group is independent.
echo ============================================================
pause

echo.
echo ============================================================
echo ROUND 2, GROUP 1/3: combined confirmation configs (1 per symbol)
echo   E9_eur_tuned    - EURUSD: all 5 Round-1 winners combined
echo                     (ADX gate on, vol-scaling on, retest-limit off,
echo                     Friday-flatten off, NY session 13-21)
echo   S5_silver_tuned - XAGUSD: baseline + ADX gate on (the one Round-1 winner)
echo   G7_gbp_tuned    - GBPUSD: baseline + vol-scaling on (the one small win)
echo ============================================================
python autotest.py --model 1 --symbol EURUSD --from 2025.07.01 --to 2025.12.31 E9_eur_tuned
if errorlevel 1 (
  echo *** E9_eur_tuned FAILED to start - see error above. Fix and re-run. ***
  goto :end
)
python autotest.py --model 1 --symbol XAGUSD S5_silver_tuned
if errorlevel 1 (
  echo *** S5_silver_tuned FAILED to start - see error above. Fix and re-run. ***
  goto :end
)
python autotest.py --model 1 --symbol GBPUSD G7_gbp_tuned
if errorlevel 1 (
  echo *** G7_gbp_tuned FAILED to start - see error above. Fix and re-run. ***
  goto :end
)

echo.
echo ============================================================
echo ROUND 2 COMPLETE. Send these 3 results back before continuing -
echo they decide whether Round 1 (below) is still worth re-running
echo on a fresh machine, or whether ROUND 1 already gave you
echo everything you need (it did, on this machine, 2026-07-20/22).
echo ============================================================
pause

echo.
echo ============================================================
echo ROUND 1 (ablation series) - SKIP if already run on this machine.
echo ============================================================
echo.
echo --- GBPUSD (7 configs) ---
python autotest.py --model 1 --symbol GBPUSD G0_raw_bin G5_session_london G6_session_ny G1_adx_gate_on G2_vol_scaling_on G3_no_retest_limit G4_no_friday_flatten
if errorlevel 1 (
  echo *** GBPUSD group FAILED to start - see error above. ***
  goto :end
)

echo.
echo --- XAGUSD (5 configs) ---
python autotest.py --model 1 --symbol XAGUSD S0_baseline S1_adx_gate_on S2_vol_scaling_on S3_no_retest_limit S4_no_friday_flatten
if errorlevel 1 (
  echo *** XAGUSD group FAILED to start - see error above. ***
  goto :end
)

echo.
echo --- EURUSD (6 configs) ---
python autotest.py --model 1 --symbol EURUSD --from 2025.07.01 --to 2025.12.31 E3_adx_gate_on E4_vol_scaling_on E5_no_retest_limit E6_no_friday_flatten E7_session_london E8_session_ny
if errorlevel 1 (
  echo *** EURUSD group FAILED to start - see error above. ***
  goto :end
)

echo.
echo ============================================================
echo ALL RUNS COMPLETE.
echo Check ..\results\regression_history.csv - if any row has a
echo non-empty "error" column, re-run just that one config:
echo   python autotest.py --model 1 --symbol ^<SYMBOL^> ^<config_name^>
echo Then zip the "results" folder and send it back.
echo ============================================================

:end
pause
