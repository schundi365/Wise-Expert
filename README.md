# Wise-Expert

Autonomous MT5 trading bot (WiseTrader EA) with a regression-testing pipeline.

## Repository layout

```
src/WiseTrader/        EA source (WiseTrader.mq5 + src/*.mqh modules)
src/WiseTraderORB/     Opening-range-breakout EA (stocks)
tools/console/         autotest.py (headless tester runner), dashboard.py
                       (Flask monitor incl. campaign card), fetch_data.py
tests/configs/         Regression .set configs (A0 baseline .. D1)
results/               Campaign evidence: tester reports, journals,
                       regression_results.csv, campaign_status.json
docs/                  Test runbook, tracker, remote tester guide,
                       feature log, build spec, user guides
.github/               CI (config/version validation), CODEOWNERS
```

## Branch model

| Branch | Purpose | Rules |
|---|---|---|
| `main` | releasable EA, protected | PR only, CI green, CODEOWNERS review |
| `develop` | integration of finished features | PR from `feature/*` |
| `feature/<name>` | one behavioral change per branch/version | branched from `develop` |
| `results/<yyyy-mm-dd>` | campaign evidence from the test VPS | pushed by the remote tester, merged via PR |
| `hotfix/<name>` | urgent fix on a release | branched from `main` |

Discipline (see CHANGELOG.md): every EA change bumps `#property version` and
the changelog together — CI fails on mismatch. One behavioral change per
version so regression deltas stay attributable.

## Quickstart

```bat
:: run the regression campaign (Windows, MT5 installed, MT5 CLOSED)
cd tools\console
python autotest.py --model 1          :: all configs, fast sweep
python autotest.py --model 0 A1_full_v20 C2_m1_close   :: tick-model runs

:: monitor from a browser
start_console.bat                     :: http://127.0.0.1:5088
```

Full procedures: `docs/WiseTrader_Test_Plan.docx` (runbook) and
`docs/WiseTrader_Remote_Tester_Guide.docx` (VPS operator guide).

## CI

Every push/PR validates: Python syntax of the tools, presence/shape of all
`.set` configs, EA-vs-CHANGELOG version consistency, and that every
`#include` the EA references exists. MQL5 compilation runs on a self-hosted
Windows runner when one is registered (job scaffolded in `ci.yml`).
