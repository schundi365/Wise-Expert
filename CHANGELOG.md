# Wise Trader — Change Log

All notable changes to the Wise Trader components. Newest first.

## WiseTrader EA v2.43 — 2026-07-20

### Added — per-symbol parameter overrides (SymbolProfile.mqh)
- New `InpUseSymbolOverrides` input (default true) and `src/SymbolProfile.mqh`:
  a symbol-keyed override table applied once in `OnInit`, so one compiled EA
  can carry tuned parameters per symbol instead of requiring manual `.set`
  swaps for live/demo multi-symbol deployment.
- Root cause this addresses: `InpProfileBin` (volume-profile bin size) is the
  **only** absolute price-unit distance input in the whole EA - every other
  distance parameter (`InpGapBufferAtr`, `InpQmZoneAtr`, `InpStopBufferAtr`,
  `InpRetestTolAtr`, `InpMaxChaseAtr`, ...) is already ATR-relative and
  self-scales across symbols. A bin size tuned for XAUUSD's ~$4300 price
  scale (0.20) collapses EURUSD's ~1.16 scale into 1-2 bins, destroying the
  POC/VAH/VAL shape (confirmed 2026-07-17: PF 0.85 -> 1.12 once retested
  with 0.0002).
- Table contents as of this version (see `SymbolProfile.mqh` for full
  evidence/citations): XAUUSD and XAGUSD use EA defaults unchanged (both
  validated as-is in the 2026-07-17 gauntlet); EURUSD overrides
  `profile_bin` to 0.0002 (validated); GBPUSD overrides to the same 0.0002
  as a reasoned but **unconfirmed** seed (similar price scale to EURUSD,
  own campaign pending - see F-log Candidate work).
- Every OnInit now journals which override (if any) fired
  (`symbol overrides [<symbol>]: <note>`), so any run is traceable.
- `InpUseSymbolOverrides=false` reproduces pre-2.43 behavior exactly (pure
  EA-input defaults regardless of symbol) - used as the ablation control
  when testing whether the override table itself is net positive per
  symbol.
- No behavioral change on XAUUSD (the currently-running demo symbol): its
  override row is a documented no-op.

## WiseTrader EA v2.42 — 2026-07-17

### Changed — A2_tuned promoted from regression config to shipped defaults
Phase 4 gauntlet (OOS, model-4 primary window, EURUSD, XAGUSD) complete;
`A2_tuned` is the validated combination and is now the EA's default behavior
instead of something you have to load via `.set`. Five input defaults
changed, all backed by the 2026-07 regression campaign
(`results/regression_history.csv`):

| Input | Old default | New default | Evidence |
|---|---|---|---|
| `InpMinAdx` | 22.0 | 0 (off) | B4_no_adx_gate: PF 1.29 → 1.48, net +$977 vs A1's +$406. Chop gate was filtering out good trades along with bad ones. |
| `InpVolRiskFloor` | 0.25 | 1.0 (= `InpVolFullRatio`, scaling flat/off) | B2_no_adaptive_sizing: PF → 1.46, net +$864. Vol-regime sizing cut winners' size along with losers'. |
| `InpBeAtrTrigger` | 1.0 | 0 (off) | D1_early_lock: avg win collapsed $38 → $16 despite higher win rate — scratching winners, not adding edge. |
| `InpLockStartPct` | 60.0 | 0 (off) | Same D1 evidence as above; progressive lock paired with early BE. |
| `InpFridayFlattenHour` | 0 (off) | 22 | D4_flatten: net positive after weighing weekend-gap losses avoided vs Friday-afternoon profit given up. |

Unchanged from A1 defaults and confirmed as keepers: `InpGapBufferAtr=0.5`
(tester understates its live value — no gap-day trades in backtest data),
`InpRetestLimit=true`, `InpMinRelVol=1.0`, `InpOutlierZ=3.5`.

Full gauntlet results, XAUUSD primary window (2026.01.01–2026.07.08, model 4):
106 trades, net +$794.23, PF 1.39, expectancy $7.49, DD 3.00%, Sharpe 4.80.
OOS (2025.07–2025.12, model 4): 147 trades, net +$1647.33, PF 1.54,
expectancy $11.21, DD 4.77%. XAGUSD cross-symbol (same primary window):
51 trades, PF 1.39, expectancy $7.98 — matches XAUUSD closely. EURUSD
cross-symbol (OOS window, `InpProfileBin=0.0002`): PF 1.12, expectancy
$2.95 — below the 1.15 win-gate, kept as secondary evidence only; XAUUSD
remains the sole deployment target.

### Fixed — carried from v2.41
See v2.41 entry below (stale hardcoded version string in journal log).

## WiseTrader EA v2.41 — 2026-07-17

### Fixed — stale hardcoded version string in journal init log
- `OnInit`'s `RECOVER` journal line (`"init: v%s test_case=..."`) was
  formatted with a hardcoded literal `"2.30"`, left over from an earlier
  version and never updated across the v2.31–v2.40 bumps. Every regression
  journal since then (A0–E1, A2_tuned, A3_tuned_nogap, the OOS and EURUSD
  runs) logged `init: v2.30` regardless of the EA's actual `#property
  version`, which was the source of the "MT5 Experts version looks ahead of
  the local project" confusion — the log line, not the compiled binary, was
  behind.
- Fix: added `#define WT_VERSION` immediately under `#property version` as
  the single source of truth, and pointed the init log at it instead of the
  literal. `#property version` is not readable at runtime, so this define
  must be bumped by hand alongside it going forward — no other file had a
  matching hardcoded-version bug (checked all `.mq5`/`.mqh` under
  `src/WiseTrader`).
- No behavioral change to trading logic; diagnostic-only fix. Prior
  regression verdicts (A2_tuned, OOS, EURUSD) are unaffected — the running
  code was correct, only its self-reported version string was wrong.

## WiseTrader EA v2.4 — 2026-07-13

### Added — protective flattens (news & weekend gap exposure)
- **Pre-news flatten** (`InpNewsFlattenMin`, default 0 = off; live only): closes
  open positions and cancels pendings N minutes BEFORE a high-impact calendar
  event for the symbol's currencies (`CNewsFilter::Upcoming`, 60 s cache).
  Complements F18, which only blocks new entries. Inert in the Strategy Tester.
- **Friday flatten** (`InpFridayFlattenHour`, default 0 = off; e.g. 22): closes
  everything from that server hour on Fridays — weekend gap risk eliminated
  (F31). Backtestable: new config `tests/configs/D4_flatten.set` (= A1 +
  Friday 22) measures gap losses avoided vs Friday profit given up.
- Both run on the 1 s timer path, journaled as `FLATTEN ALL: pre-news flatten:
  <event>` / `Friday flatten: weekend gap protection`.
- Defaults OFF to keep all existing regression configs comparable; enable
  explicitly for live deployment.

Components: **WiseTrader EA** (metals/FX), **WiseTraderORB EA** (stocks), **Console** (Flask dashboard).
After any EA change: recompile in MetaEditor (F7); attached charts reload automatically.

---

## Console v1.3 — 2026-07-10

### Fixed — "no report produced" on every run (4–5 s exits)
- **Data-folder matching**: the launched terminal uses the data folder tied to its
  install path; `find_data_dir()` now resolves it via each hash folder's `origin.txt`
  instead of guessing by contents (wrong-hash guess = EA not found = instant abort).
- **Report path**: `Report=` is treated by MT5 as a name relative to the data folder;
  the absolute path with spaces silently failed. Reports are now written locally and
  moved into `Tester Sets\` afterwards.
- **Self-diagnosis**: on any failed run the script prints the tail of the terminal's
  own log, so the real abort reason is visible in the console output.

## Console v1.2 — 2026-07-10

### Added — local-folder workflow (autotest.py)
- **Directory junction**: `<MT5 data>\MQL5\Experts\WiseTrader` is auto-linked to the
  project folder; no more copying files into the MT5 data folder. An existing real
  folder is backed up to `WiseTrader_backup_<timestamp>` on first run.
- **Auto-compile**: `metaeditor64.exe /compile` runs before each campaign through the
  junction; campaign aborts on compile errors (`--skip-compile` to bypass).
- **Journal collection**: tagged run journals are copied from Common\Files into
  `Tester Sets\journals\` so all evidence lives in the project folder.
- `find_data_dir()` now handles fresh setups (no EA in the data folder yet).
- TESTING.md section 2 rewritten for the local-folder workflow.

## WiseTrader EA v2.3 — 2026-07-10

### Added — test-case tagging (regression log hygiene)
- `InpTestTag` input: names the test case. Tagged runs write to their own journal
  (`WiseTrader_<sym>_<magic>_<tag>.csv` in Common\Files) so regression runs never
  mix in one CSV; the init RECOVER line now logs EA version + test_case.
- All 16 `.set` configs in `Tester Sets/` now carry `InpTestTag=<config name>`.
- Live/demo runs with an empty tag keep the original filename — no migration needed.

## Tester kit — 2026-07-10 (no code change)

### Added
- `D2_soft_lock.set` — D1 with lock start 60→80%, lock 50→33%, partial 50→25%.
- `D3_be_only.set` — D1 with progressive lock and partial exits OFF (ATR breakeven only).
- `E1_silver_D1.set` — D1 with `InpProfileBin` 0.20→0.02 (XAGUSD-correct volume profile).

### Context (XAGUSD Mar–Jun 2026 run, 226 deals, net +$128, PF 1.03)
- Sizing verified fixed (all losses ≤ 1%). New bottleneck: v2.2 management scratches
  winners — avgWin $31 vs avgLoss $62, max win ~1R, zero TP hits. Hypothesis to test:
  A1 vs D1 vs D2 vs D3 on identical data. Silver runs also suffered a gold-sized
  profile bin (use E1) and 67 min-lot vetoes on the $10k account.

## Project — 2026-07-13: CI/CD repository layout (Wise-Expert)

### Changed
- Remote: `https://github.com/schundi365/Wise-Expert.git`. New layout after
  running `setup_git.bat` (restructure + init + push, run once on Sri's PC):
  `src/` (EAs), `tools/console/`, `tests/configs/` (.set), `results/`
  (campaign evidence), `docs/` (all documents), `.github/` (CI + CODEOWNERS).
- Branch model: protected `main` (PR + CI), `develop`, `feature/*`,
  `results/<date>` (VPS campaign evidence), `hotfix/*` — see README.md.
- CI (`.github/workflows/ci.yml`): Python syntax, .set config shape, EA
  `#property version` == newest CHANGELOG entry, `#include` existence.
  MQL5 compile job scaffolded for a self-hosted Windows runner.
- `.gitignore`: Claude/AI workspace files (`.claude/`, `CLAUDE.md`,
  `.mcp.json`), compiled/log/lock artifacts.
- `autotest.py`/`dashboard.py` paths updated to the new layout; stale MT5
  junctions to the old path are detected and relinked automatically.
- Runbook + Remote Tester Guide updated (paths, clone URL, results branches).

## Console v1.2 — 2026-07-13

### Added — autotest ↔ dashboard integration
- `autotest.py` now writes `Tester Sets/campaign_status.json` before/after every
  run (configs, current, per-run results, finished flag). Monitoring failures
  never abort a campaign.
- `dashboard.py`: new `/api/campaign` endpoint + "Test campaign" card — state
  (RUNNING / FINISHED / STALLED if no update >10 min), progress N/M, current
  config, and a results table (net, PF, trades, DD, errors) refreshing every 5 s.
  Campaign progress is now visible from a browser (e.g. phone) without watching
  the command window.

## WiseTrader EA v2.2 — 2026-07-09

### Fixed — stop not moving to safety while price ran toward TP
Root cause: geometry, not a dead code path. BE armed only at 1R of profit, but
stops are wide (1.5×ATR floor, protective swings 2–3×ATR) while TP is capped at
3×ATR — so the trigger sat 50–80% of the way to TP and most trades reversed
before the stop ever moved.
- **ATR breakeven trigger** (`InpBeAtrTrigger` 1.0): BE (and the partial exit)
  now arms at `min(1R, 1×ATR)` of profit — wide-stop trades protect early.
- **Progressive profit lock** (`InpLockStartPct` 60, `InpLockPct` 50): once 60%
  of the entry→TP distance is covered, the stop locks 50% of the open profit,
  ratcheting with price. Independent of BE state; never regresses. If the lock
  is what first carries the stop past entry, the partial banks there too
  (once-only invariant preserved).
- **Rejected `PositionModify` calls are now journaled** (`modify … rejected
  rc=`), throttled to one line per 30 s — silent broker rejections (stops
  level, freeze level) were previously invisible.
- Tester configs: all existing .set files pin v2.2 management OFF for
  comparability; new `D1_early_lock.set` = A1 + v2.2 management (compare vs A1).

### Migration
- Recompile. Set `InpBeAtrTrigger=0` / `InpLockStartPct=0` for v2.1 behavior.

## WiseTrader EA v2.1 — 2026-07-09

### Added — early entry (kills bar-close latency)
Signals previously entered up to 15 min after the actual break (M15 close wait)
and retests filled only on a closed-bar touch. Three mechanisms, regression-testable:
- **Retest limit orders** (`InpRetestLimit`, default true): retest setups place a
  resting limit at the retest price with SL/TP attached — filled the instant the
  pullback touches, instead of waiting for a closed M15 bar. Bar-close touch flow
  remains as fallback when the limit can't be placed. Comment suffix `|RL`.
- **Break entry modes** (`InpBreakEntryMode`):
  `M15_CLOSE` (default, unchanged) | `M1_CLOSE` — M15 levels checked against M1
  closes, entry ~1 min after the break, keeps close confirmation | `STOP_ORDER` —
  resting stop at level + `InpStopBufferAtr`×ATR (default 0.05), instant fill but
  NO close confirmation (every wick poke fills; comment suffix `|SO`). Stop mode
  trades with-trend BOS only; CHoCH keeps close confirmation. All gates (ADX,
  relVol, outlier, score, news, session, risk) apply to every mode.
- **Pending-order lifecycle**: one resting order max; cancelled on setup
  expiry/invalidation/supersession and orphan-cleaned after terminal restart;
  entry fills consume the setup via `OnTradeTransaction` (DEAL_ENTRY_IN).
- `CMarketStructure::BreakCheck/ConsumeLevel/ClearEvent`,
  `CSignalEngine::EvaluateBreak` (shared by M15/M1/stop paths),
  `CExecutor::PlaceLimit/PlaceStop/CancelPending/PendingCount`, `ComputeTp` helper.
- **Tester configs**: `C1_retest_limit`, `C2_m1_close`, `C3_stop_orders`
  (A1 kept as unchanged reference: M15 close, touch-based retest).

### Known limitations
- In `STOP_ORDER` mode a resting stop can block a same-bar close-confirmed CHoCH
  market entry (pending owns the entry); the FSM retry resolves it a bar later.
- M1 relVol gate uses the last closed M15 bar's volume (forming-bar volume is partial).
- In the Strategy Tester use model 0/4 (tick-based) for `M1_CLOSE` and
  `STOP_ORDER` runs — model 1 (M1 OHLC) is fine for M1_CLOSE but understates
  stop-order slippage.

### Migration
- Recompile. Defaults preserve v2.0 behavior except retest limits (ON — strictly
  better fills at the same price). Run C1→C3 via autotest to pick the entry mode
  on evidence.

## Console v1.1 — 2026-07-09

### Added
- **`autotest.py`** — unattended regression runner: drives `terminal64.exe`
  headlessly (`/config`) through every `.set` in `Tester Sets/`, one tester run
  per config, parses each `.htm` report and writes
  `Tester Sets/regression_results.csv`. `--model 1` (M1 OHLC) for fast sweeps,
  `--model 4` (real ticks) for final validation. Close MT5 before running.
- **`fetch_data.py`** — export symbol bars (OHLCV + tick volume + spread)
  from the running terminal to CSV for offline analysis.

## WiseTrader EA v2.0 — 2026-07-09

### Added — F10 relative volume + F16 outlier bar mask
- **F10 "in play" filter** (`src/RelVolume.mqh`; `InpMinRelVol` 1.0,
  `InpRelVolDays` 20): BOS/CHoCH entries require the signal bar's tick volume
  ≥ the average of the same time-of-day bar over the past 20 sessions.
  Breaks without participation are vetoed (`volume: relVol`). Missing
  baseline (weekends/history gaps) = gate stands down, never vetoes.
  RelVol journaled in setup evidence. QM exempt.
- **F16 outlier bar mask** (`src/Outliers.mqh`; `InpOutlierZ` 3.5, window 100):
  modified Z-score (median/MAD of true range, spike excluded from its own
  baseline). Outlier bars are ignored entirely: no signal generation, no FSM
  aging, no retest confirmation on spike touches (`outlier bar masked` veto).
  `CleanAtr(14)` — ATR over non-outlier bars — now drives stop-floor
  validation, QM zones and the TP cap, so one news candle no longer doubles
  every threshold for the next 14 bars. Raw ATR still used for trailing and
  gap-buffer sizing (those should see real volatility). Works in the
  Strategy Tester, unlike the calendar filter.
- `CSignalEngine::Poll` signature: new `relvol` parameter.
- `InpMaxChaseAtr=0` now disables ALL retest logic including the v1.9 CHoCH
  forced retest (needed so the regression baseline config is reachable).
- **Regression test kit** (`Tester Sets/`): 9 `.set` configs — A0 baseline,
  A1 full, B1–B7 each disabling ONE feature — plus
  `WiseTrader_Regression_Matrix.xlsx` (protocol, results grid, auto-computed
  per-feature contribution vs A1). One behavioral change per version from now on.

### Migration
- Recompile. Set `InpMinRelVol=0` / `InpOutlierZ=0` to disable individually.

## WiseTrader EA v1.9 — 2026-07-09

### Changed — journal-driven tuning (from Jan–Mar 2026 XAUUSD tester log)
Data: 86 closed deals, net +$113 (breakeven). BOS +$251 avg +6.62; CHoCH −$138
avg −2.87. By close hour: 15–19h +$509, 03–10h −$384. TP hit 11× vs SL 51×.
- **CHoCH demoted**: base weight 0.35 → 0.30 (same as BOS — counter-trend gets
  no premium) and CHoCH now ALWAYS waits for the pullback retest; it can no
  longer market-enter on the breakout bar regardless of chase distance.
- **Session window default 12–20** (was 7; user log ran 3–20): drops the
  Asian/early-London chop hours, keeps the London–NY overlap that carried
  all the profit (F14). Revisit with a full 6-month journal.

### Known issue (watch next run)
- 19 vetoes `size 0.00 < broker min` on a $10k account: high-vol trades where
  the vol-scaled budget can't fund 0.01 lots on a wide gold stop. Correct
  behavior (min lot would breach budget), but it skips some high-ADX setups;
  consider higher equity or `InpVolRiskFloor` 0.4 if too many good trades skip.

## WiseTrader EA v1.8 — 2026-07-09

### Added — signal quality overhaul (backtest losing-streak fix)
- **Max-chase veto + retest entry** (`InpMaxChaseAtr` 0.75, `InpRetestTolAtr` 0.25,
  `InpRetestMaxBars` 8): breakout bars closing > k×ATR beyond the broken level are
  no longer bought at market; the setup enters the FSM FORMING state (F32) and
  executes only when price pulls back to level + tolerance. Kills the
  "entry 34 pts past the level, 41-pt stop" chase trades. Journaled `AWAIT-RETEST`.
- **Chop stand-down** (`InpMinAdx` 22, F15-lite): BOS/CHoCH entries require
  ADX(14) ≥ threshold on the decision TF; range-boundary whipsaws are vetoed
  (`regime: chop`). QM reversals are exempt. ADX > 30 adds +0.10 score to BOS.
- **News blackout** (`InpNewsFilter`, `InpNewsBlockMin` 30, F18, new
  `src/NewsFilter.mqh`): no new entries ±30 min around high-impact calendar
  events for the symbol's currencies. Inactive in Strategy Tester (no calendar
  data there) — live protection only.

### Changed — confluence scoring rebalance
- **Ehlers cycle credit fixed**: was rewarding longs with the wave already high
  (buying cycle tops); now requires the wave to be *turning* with the trade and
  not extended (`CycleTurn` evidence). `CEhlers::WavePrev()` added.
- VWAP-side weight 0.20 → 0.10 (nearly always true for breakouts — was free score).
- Default `InpMinScore` 0.45 → 0.55: base + VWAP alone can no longer trade;
  at least one real confirmation (VP node, cycle turn, strong ADX) is required.

### Migration
- Recompile; re-run the 6-month backtest. Expect far fewer trades (chop and
  chase vetoes) — judge by expectancy, not trade count. Set `InpMaxChaseAtr=0`,
  `InpMinAdx=0`, `InpMinScore=0.45` to reproduce v1.7 behavior.

## WiseTrader EA v1.7 — 2026-07-09

### Added — adaptive T/P and lot sizing (win/loss asymmetry fix)
- **ATR-capped take-profit** (`InpTpCapAtr`, default 3.0): TP distance capped at
  k×ATR so targets stay reachable in the current regime; never capped below
  `InpMinRR` × stop. Capping is journaled (`TP capped`).
- **Partial exit at the breakeven trigger** (`InpPartialPct`, default 50%): banks
  half the position at 1R before the trail runs, so winners no longer exit near
  breakeven while losers take the full stop. Restart-safe: SL is moved to BE
  first, and SL-at-entry doubles as the partial-done flag — no double partials.
  Respects broker volume min/step; skipped harmlessly on positions too small to split.
- **Gap-buffered sizing** (`InpGapBufferAtr` 0.5, `InpGapLookback` 20): lots are
  sized as if the stop fills `max(k×ATR, worst recent open gap)` beyond the placed
  SL, so gap slippage stays inside the risk budget.
- **Volatility-regime risk scaling** (`InpVolFullRatio` 1.0, `InpVolMinRatio` 2.0,
  `InpVolRiskFloor` 0.25): risk% scales linearly from full at ATR14/ATR100 ≤ 1.0
  down to 25% at ratio ≥ 2.0.
- Sizing evidence journaled on every fill (`sizing: vol_ratio=… scalar=… gap_buf=…`).

### Migration
- Recompile; new inputs default to ON. Set `InpTpCapAtr=0` / `InpPartialPct=0` to
  restore v1.6 exit behavior.

## WiseTrader EA v1.6 — 2026-07-08  ⚠ CRITICAL

### Fixed
- **Position sizing oversized trades ~10–15x on gold** (tick-value arithmetic mispriced
  XAUUSD loss-per-lot on some broker specs; backtests risked 10–16% per trade instead of 1%,
  tripping the total-DD lock within days). Sizing now uses `OrderCalcProfit` — broker-exact,
  handles contract size and account-currency conversion. Fallback: contract-size arithmetic.
- Added **sizing sanity clamp**: any trade whose worst-case loss exceeds the risk budget
  by >20% is vetoed (`sizing sanity clamp` in journal) — a sizing error can never reach
  the market again.
- `CRiskManager::CanOpen` signature changed: now takes direction as first argument.

### Migration
- Re-run all backtests; results before v1.6 are invalid (sizing bug dominated outcomes).

## WiseTrader EA v1.5 — 2026-07-08

### Added
- **Dashboard command bridge** (`src/Commands.mqh`): polls `WiseTrader_<sym>_<magic>.cmd`
  in Common\Files every second — PAUSE / RESUME / FLATTEN / CLEAR_LOCK, with `.ack` reply.
- **Status snapshots**: `WiseTrader_<sym>_<magic>.status.json` written every second
  (regime-ready state, lock, equity anchors, VWAP/POC/cycle, positions).
- Dashboard pause vetoes journaled as `dashboard pause`.

## Console v1.0 — 2026-07-08

### Added
- Flask operations console (`Console/dashboard.py`, port 5088): live status cards,
  open positions, 30-day performance via MetaTrader5 Python package, color-coded live
  journal with tag filters, Pause/Resume/Flatten/Clear-lock buttons with EA acknowledgment.
- `start_console.bat` launcher; `WT_SYMBOL`/`WT_MAGIC`/`WT_PORT` env overrides.

## WiseTraderORB EA v1.1 — 2026-07-08  ⚠ CRITICAL

### Fixed
- Same sizing fix as WiseTrader v1.6: `OrderCalcProfit`-based loss-per-lot.

## WiseTraderORB EA v1.0 — 2026-07-08

### Added
- Opening Range Breakout system for US stocks (SFI / Zarattini 2024, from
  "Low-Frequency Quantitative Strategies Part 4"): eligibility screen, relative
  opening-volume "Stocks in Play" filter, first-candle bias, stop orders at range edge,
  0.1×ATR(14d) stop, no TP, 15:55 ET flatten, risk split across symbols,
  daily-loss skip + total-DD lock (account-keyed), buffered journal, ET/DST handling.

## WiseTrader EA v1.4 — 2026-07-08

### Added
- `InpSymbol` input: symbol override ("" = chart symbol); validates against Market Watch.

### Improved
- Session-window vetoes now show server hour and configured window
  (`outside session window (server hour 23, window 07-20)`).
- Global-lock vetoes now name the lock (`global lock (DAILY_LOSS)`).
- `LockName()` helper added to Config.mqh; `CanTrade` takes the lock enum.

## WiseTrader EA v1.3 — 2026-07-07

### Changed
- Journal lines echoed to Experts tab / tester Journal via `Print` (live visibility).
- Journal CSV moved to **Common\Files** (one location for live charts and tester runs).

## WiseTrader EA v1.2 — 2026-07-07

### Fixed
- **Phantom drawdown locks**: risk counters were keyed only by magic+symbol, so stale
  equity anchors leaked between accounts and instantly locked new runs (observed: lock
  before first trade, phantom total-DD flatten). Keys now include account login.

### Added
- `InpResetRiskState` input: wipe persisted risk state on init.
- Init journal line now logs equity / day_eq / peak_eq for instant diagnosis.

## WiseTrader EA v1.1 — 2026-07-07

### Changed
- Default confluence threshold `InpMinScore` 0.55 → 0.45 (0.55 was nearly unreachable
  when M1-based analytics were unavailable; BOS+VWAP scores 0.50).

### Added
- "Last veto" line on the chart dashboard — live reason for the most recent rejection.
- Failed orders on still-valid (ACTIVE) setups retried on the next bar.

## WiseTrader EA v1.0 — 2026-07-07

### Added
- Initial Phase 1 MVP per Build Specification v1.0 (14 files):
  cooperative time-budgeted scheduler; incremental session VWAP, session volume profile
  (POC/Value Area), Ehlers roofing filter + Even Better Sinewave; market structure
  (S1–S4 swings, BOS/CHoCH) and Quasimodo detectors; confluence scorer; discipline FSM
  with CanTrade authorization; risk manager (1%/3%/10% Moderate profile, streak lock,
  restart-safe counters); executor with bounded retries; breakeven + ATR/structure
  trailing (restart-aware by stop inference); buffered CSV journal; chart dashboard.

---

*Maintained by Claude. Each functional change bumps the component version here and in
the EA's `#property version`.*
