# Wise Trader — Change Log

All notable changes to the Wise Trader components. Newest first.

## WiseTrader EA v2.54 — 2026-09-03

### Added — F59 aggressive volume-confirmed momentum-breakout entry, OFF by default
- New `src/MomentumBreak.mqh` (`CMomentumBreak`): a deliberate INVERSION of
  the F16 outlier mask. Where the rest of the engine treats a high-sigma
  bar as noise to veto, F59 treats a sharp, volume-backed, directional
  expansion bar as the start of a run to ride. Motivation: A2_tuned
  structurally sits out fast directional moves (a $50 XAUUSD run vetoed as
  a z=9.9 outlier); this is the opt-in path that participates — cautiously,
  gated on volume.
- Trigger (all required, on the just-closed bar): true-range modified-Z
  `>= InpMomExpansionZ` (expansion), close in the top/bottom
  `InpMomCloseFrac` of the bar range (conviction, not a rejection wick), and
  relative volume `>= InpMomMinRelVol` (real participation — this is the
  "consider volumes" filter separating genuine runs from fakeouts). Spread
  gate (F58) is applied on top and is mandatory here — never chase into
  toxic flow.
- **Stop-loss precautions (the whole point of "aggressive but safe"):**
  1) MANDATORY hard SL — the setup routes through `CRiskManager::CanOpen`
     exactly like every other entry, which rejects a zero/absent stop and
     sizes off it; a stopless F59 position is impossible by construction.
  2) Tight stop — the opposite extreme of the expansion bar, floored to
     `InpMomStopAtr * ATR`; the engine's global ATR stop-floor + min-RR
     (`ValidateSetup`) still apply on top.
  3) Time-based STALL EXIT — an F59 trade not yet at breakeven within
     `InpMomMaxBars` decision bars is closed early (`CTradeManager::Manage`,
     restart-safe via `POSITION_TIME` + order comment).
  4) Full risk gating — same daily-loss / total-drawdown / streak locks,
     session window, and news blackout as structure entries; managed by the
     same breakeven / trailing / profit-lock.
- Evaluated in `OnNewBar` BEFORE the outlier mask (so it can act on the very
  bars the mask rejects). `InpUseMomBreak=false` (default) makes
  `TryMomentumBreak()` a no-op — v2.53 behavior is reproduced exactly.
- New inputs: `InpUseMomBreak` (off), `InpMomExpansionZ` (3.0),
  `InpMomCloseFrac` (0.30), `InpMomMinRelVol` (1.8), `InpMomStopAtr` (1.0),
  `InpMomMaxBars` (6). Added `WT_SIG_MOMENTUM` signal type and a `SetupTag()`
  order-comment helper. All `tests/configs/*.set` updated; new ablation
  config `M1_momentum_breakout` (= `A2_tuned` + `InpUseMomBreak=true` +
  spread gate on) vs `A2_tuned`.
- Status: Candidate, pending backtest — see Feature Log F59. HONEST
  EXPECTATION: momentum entries collapse out-of-sample more than most
  (cf. F52/F53 rejections); this must clear standalone -> OOS -> model-4 ->
  WFE overfit scoring before it earns a demo slot, and should run on its own
  magic number so it never entangles with A2_tuned's risk state.

## WiseTrader EA v2.53 — 2026-09-03

### Added — F58 spread Z-score entry gate (execution-cost veto), OFF by default
- New `src/SpreadGate.mqh` (`CSpreadGate`): rolling mean/stddev of the
  per-bar spread (`CopySpread`, points) over `InpSpreadPeriod` (default 40)
  bars; `ZScore()` returns how far the just-closed bar's spread sits above
  its recent baseline. A BOS/CHoCH break firing while the spread is an
  outlier high = "toxic flow" (wide, thin, expensive fills that bleed the
  edge on market/stop entries). New veto in `SignalEngine::EvaluateBreak()`,
  right after the F10 relative-volume gate: reject when
  `spread_z >= InpSpreadZMax`. Applies to structure breaks only (not QM),
  same scope as the relvol gate.
- Distinct from the F16 price-outlier mask (that masks abnormal PRICE
  candles; this watches bid/ask COST only) and from `Risk.mqh`'s gap buffer
  (that sizes for slippage; this refuses the trade outright). Clean-room
  reimplementation of the rolling-spread-Z idea — not derived from any
  third-party source.
- Follows the `RelVolume` "no data = stand down" convention: `ZScore()`
  returns the `WT_SPREAD_Z_NA` sentinel when fewer than 10 valid samples
  exist or the window has zero dispersion, and the veto treats that as NO
  gate, never a rejection.
- `InpSpreadZMax=0` (default) disables the gate and reproduces v2.52
  behavior exactly. New inputs `InpSpreadZMax` (0 = off) and
  `InpSpreadPeriod` (40). All `tests/configs/*.set` updated. New ablation
  config `Z1_spread_gate` (= `A2_tuned` + `InpSpreadZMax=2.0`) vs `A2_tuned`
  at XAUUSD M15. Status: Candidate, pending backtest — see Feature Log F58.
- Housekeeping: moved 5 third-party/standalone `.mq5` programs (Spread
  Monitor, Volatility Regime, Global Macro Soros, two Quantora managers)
  out of `src/WiseTrader/src/` to `reference/thirdparty_mql5/` so they can
  never contaminate the EA build. F58 is an original reimplementation of
  the spread-Z concept those files inspired, not their code.

## WiseTrader EA v2.52 — 2026-08-07

### Fixed — F57 MtfBias() 4805 (ERR_INDICATOR_CANNOT_CREATE): prime H1 history before iMA()
- ROOT CAUSE (finally confirmed, not guessed): in a single-symbol M15
  headless backtest the tester does NOT build the secondary H1 timeframe
  until the EA actually ACCESSES it. Creating the `iMA()` handle alone did
  not count as an access on build 6093, so `iMA()` returned 4805 and
  `m_mtf_ma_handle` stayed INVALID for the ENTIRE run. The v2.51 `MTFdbg`
  instrumentation proved it directly: the 2026-08-06 `Y1_mtf_h1_on` tester
  log carries `cannot load indicator 'Moving Average' (XAUUSD) [4805]` and
  every evaluated setup shows `|MTFdbg:handle_invalid err=4805`. That run
  still "passed" at net +$893.38 - IDENTICAL to `A2_tuned` - precisely
  because the MTF bonus never once fired. So the two prior "fixes" (v2.50
  lazy-retry, v2.51 instrumentation) were measuring a feature that had
  never activated, not a feature that didn't help.
- FIX: new `PrimeMtfHistory()` does an explicit `CopyRates(mtf_tf,...)` to
  force the tester to synchronize the H1 series (per MT5 tester docs: the
  run pauses to download missing symbol/TF data on first access), THEN
  creates the handle. Applied in both `Init()` and the lazy-retry path in
  `MtfBias()`, so it self-heals if H1 isn't ready on the very first bar.
  `MtfBias()` now reports `htf_history_not_ready` distinctly from
  `handle_invalid` so a future failure is unambiguous.
- `InpUseMtf=false` (default) is unchanged: no H1 access at all when the
  feature is off, preserving the earlier "no history-cache build error on
  the default path" property. `Y1_mtf_h1_on` must be rerun against v2.52 to
  get F57's FIRST real verdict - all prior runs measured "never activated."

## Tooling — Console/wfe_score.py added — 2026-08-06

### Added — F51 Walk-Forward Efficiency scoring (Python, no EA change)
- New `Console/wfe_score.py`: reimplements the WFE scoring math from
  "Implementing Walk-Forward Efficiency Ratio Scoring in MQL5 to Detect
  Over-Optimized Strategies" (MQL5 Articles, 2026-07-09) - `WFE =
  SR_OOS / SR_IS`, with the non-positive-IS guard (WFE=0, also blocks the
  double-negative false positive) and near-zero-IS guard (WFE=0 below
  Sharpe 0.25, avoids an exploding ratio from a near-zero denominator).
  Pass threshold 0.5 (retains at least half of in-sample efficiency), per
  the source article.
- Deliberately reuses the Sharpe ratio MT5's own tester report already
  computes (already sitting in `results/regression_history.csv`) instead
  of re-deriving Sharpe from a per-bar equity series - no companion
  EA/journal change needed, matching the Feature Log's own plan for a
  lightweight first implementation.
- First real test (4 known campaign pairs, hardcoded in `KNOWN_PAIRS`):
  `A2_tuned` PASS (WFE 1.18), `W1_volregime_on` PASS (WFE 1.06 - confirms
  F55 genuinely generalized, a more precise read than this session's
  "parity" framing), `E9_eur_tuned` FAIL (WFE -0.68), `S5_silver_tuned`
  FAIL (WFE -0.46) - correctly flags both known overfit collapses. Tool
  works as intended - see Feature Log F51.
- Supports ad-hoc scoring (`--is-sharpe`/`--oos-sharpe`) and CSV lookup by
  config+symbol+period for future campaigns; IS/OOS role per config isn't
  auto-detectable from the CSV (direction flips per campaign - E9's own
  tuning window was 2025H2, everyone else's was the 2026 primary window),
  so `KNOWN_PAIRS` is hand-curated and should be extended as new
  campaigns land.

## WiseTrader EA v2.51 — 2026-08-05

### F52-F57 movement-signal series — closed out, none promoted
- v2.51's diagnostic rerun (`Y1_mtf_h1_on`) failed outright (no report,
  96s) - third attempt at F57 without ever producing usable evidence.
  DEPRIORITIZED per user decision 2026-08-06 rather than keep spending
  test cycles on what looks like a tester-environment/tooling issue
  unrelated to the feature's own logic - not rejected on merit, just
  unresolved.
- Final scorecard: F52 (momentum) rejected, F53 (regression slope)
  rejected, F54 (cycle weight) rejected (zero effect), F55 (vol-regime)
  real in-sample edge but only at PARITY OOS - not promoted, F56
  (persistence) rejected, F57 (MTF) inconclusive/deprioritized.
- Demo account stays on `A2_tuned` unchanged - none of the six candidates
  cleared the bar this project set for itself (genuine OOS improvement,
  not just survival), and the demo's clock had just been reset 4 days
  earlier for the [[wise-trader-demo-tracking]] journal-contamination
  issue. All six inputs remain in the EA (default off/false) as
  documented, gauntlet-tested candidates for future reconsideration
  rather than being ripped out.

### Debug — F57 still silent after two fix attempts, added instrumentation
- Neither the v2.50 lazy-retry fix nor manually reloading H1 history in
  MT5 resolved it: `Y1_mtf_h1_on` reran twice more (2026-08-02, 2026-08-05)
  and the `|MTF...` evidence tag still never appeared once across any
  evaluated setup in either run's isolated journal segment. Guessing a
  third root cause isn't productive without evidence.
- `MtfBias()` now takes a `string &dbg` out-param and always reports which
  exact step failed (`handle_invalid`, `htf_close<=0`, or
  `copybuffer_ret=N`, each with `GetLastError()`) or the actual close/MA
  values on success. `Score()` appends this as `|MTFdbg:...` to EVERY
  evaluated setup's evidence (not just aligned ones), so the next run's
  journal will show the real cause directly instead of staying silent.
  Temporary - remove once F57's actual failure mode is confirmed.

## WiseTrader EA v2.50 — 2026-08-01

### Fixed — F57 MtfBias() never fired (secondary-TF handle race)
- `Y1_mtf_h1_on`'s first run (2026-08-01) produced results IDENTICAL to
  `A2_tuned` across all 354 evaluated setups in the journal - the `|MTF...`
  evidence tag never appeared once. Root cause: `m_mtf_ma_handle` (the H1
  EMA handle) was only created once, in `Init()`; MT5's tester can return
  `INVALID_HANDLE` for a SECONDARY timeframe's indicator handle if that
  timeframe's history hasn't been built yet at the exact moment `OnInit`
  runs (a known quirk - unlike the decision-TF handles, which the tester
  always has ready). With no retry, the handle stayed invalid for the
  entire run and `MtfBias()` silently returned `WT_DIR_NONE` every time -
  indistinguishable from a genuine null result without checking the
  journal directly.
- Fix: `MtfBias()` now retries `iMA()` lazily on every call while the
  handle is invalid, instead of only attempting creation once in `Init()`.
  Self-healing, matches the project's existing restart-safe philosophy
  elsewhere in the EA.
- `Y1_mtf_h1_on` needs to be rerun against this fix before any real F57
  verdict can be recorded - the prior run measured "the feature never
  activated," not "the feature doesn't help."

### F55 vol-regime - full gauntlet result
- Model 4 confirm (2026.01.01-2026.07.08, in-sample): 107 trades, net
  $925.60, PF 1.47, exp $8.65, Sharpe 4.91 - vs `A2_tuned`'s own model-4
  primary-window number (106 trades, $794.23, PF 1.39, exp $7.49, Sharpe
  4.80, from the original gauntlet): still a real edge (PF +0.08, exp
  +15%), confirming the model-1 result wasn't a fill-model artifact.
- OOS (2025.07.01-2025.12.31, untouched window), model 4: 155 trades, net
  $1651.99, PF 1.51, exp $10.66, Sharpe 5.20, DD 5.28%/6.06% - vs
  `A2_tuned`'s own OOS number on the same window (147 trades, $1647, PF
  1.54, DD 4.8%, from the original 2026-07-17 gauntlet): essentially AT
  PARITY, marginally behind on PF (1.51 vs 1.54) and DD (5.28% vs 4.8%).
  Unlike `E9_eur_tuned` this does NOT collapse OOS - it's a real,
  reproducible in-sample edge - but it also doesn't clearly beat the
  existing validated baseline once OOS is accounted for. Verdict: NOT
  promoted to default. `InpUseVolRegime` stays available (default false)
  as a documented, gauntlet-tested candidate for future reconsideration
  rather than being treated as either a win or a dead end.

### F56 persistence - campaign verdict recorded
- REJECTED: `X1_persistence_on` vs `A2_tuned` (XAUUSD M15,
  2026.01.01-2026.07.08, model 1) - net $893->$790 (-12%), PF 1.44->1.36,
  exp $8.43->$7.18 (-15%), max DD 2.94%->3.74%, Sharpe 5.34->4.51 (-16%),
  n=106->110. Confirmed genuinely active in the journal (`VR=` tag present
  on many setups, ranging 1.15-1.26+) - a real result, not a dead feature
  like F57's bug. Same dilution pattern as F52/F53: admits more marginal
  trades past `InpMinScore`, net negative. `InpUsePersistence` stays in
  the EA (default false).

## WiseTrader EA v2.49 — 2026-07-28

### Added — F57 multi-timeframe agreement confluence score, OFF by default
- New scored input in `SignalEngine::Score()`: a higher timeframe
  (`InpMtfTf`, default H1) closing above/below its own EMA(`InpMtfMaPeriod`,
  default 50) agreeing with the trade direction adds `InpMtfWeight`
  (default 0.15) to the score. New helper `CSignalEngine::MtfBias()`.
  Different failure mode than F52-F56 (all of which read the SAME
  timeframe more carefully) - this catches "M15 broke a level but H1 is
  still ranging/opposed," which no amount of M15-only signal work can see.
- The HTF indicator handle is only created in `Init()` when
  `InpUseMtf=true` - deliberately avoids pulling H1 history at all when
  the feature is off (default), sidestepping the "history cache build
  error" the earlier H1-`InpTF` ablation configs hit. When actually
  testing this feature (`InpUseMtf=true`), that same error may still
  surface since it now pulls H1 data regardless of chart period - if so,
  open an H1 chart for the symbol once to force history download, per the
  note already in `Y1_mtf_h1_on.set`.
- `InpUseMtf=false` (default) reproduces v2.48 behavior exactly. All
  `tests/configs/*.set` files updated. New ablation config:
  `Y1_mtf_h1_on` vs `A2_tuned` at M15, XAUUSD. Status: Candidate, pending
  backtest - see Feature Log F57. This is the last of the F52-F57
  movement-signal candidate series.

## WiseTrader EA v2.48 — 2026-07-28

### Added — F56 persistence (variance-ratio) confluence score, OFF by default
- New scored input in `SignalEngine::Score()`: a Lo-MacKinlay-style
  variance-ratio test (`PersistenceRatio()`, non-overlapping q-blocks over
  `InpPersistenceLookback`=60 bars, block size `InpPersistenceQ`=5)
  exceeding `InpPersistenceMinVr` (default 1.15) adds
  `InpPersistenceWeight` (default 0.15) to the score. VR>1 = trending/
  persistent returns, VR<1 = mean-reverting, VR~1 = random walk.
  Directionless, same style as F55 - this asks whether the CURRENT REGIME
  deserves trust for a bar-based breakout at all, not which direction to
  trade. NOT a literal Hurst exponent (that needs multi-scale R/S
  regression) - documented honestly as the simpler, equally standard
  variance-ratio proxy for the same "Feature Engineering Part 9:
  Structural Break Tests" family of question.
- `InpUsePersistence=false` (default) reproduces v2.47 behavior exactly.
  All `tests/configs/*.set` files updated. New ablation config:
  `X1_persistence_on` vs `A2_tuned` at M15, XAUUSD. Status: Candidate,
  pending backtest - see Feature Log F56.

## WiseTrader EA v2.47 — 2026-07-28

### Added — F55 volatility-regime (ATR expansion) confluence score, OFF by default
- New scored input in `SignalEngine::Score()`: ATR14/ATR100 ratio exceeding
  `InpVolRegimeMinRatio` (default 1.3) adds `InpVolRegimeWeight` (default
  0.15) to the confluence score. Directionless (applies to longs and shorts
  alike) - unlike F52/F53 this isn't about trade direction, it's about
  whether the market is in an expansion regime at all.
- Deliberately a SEPARATE read from `Risk.mqh`'s own ATR14/ATR100 handles,
  which drive position sizing (and treat high ratio as a reason to shrink
  risk, currently disabled by default per the original campaign). Mixing
  the sizing and scoring concerns into one shared value would have made
  either change hard to attribute.
- `InpUseVolRegime=false` (default) reproduces v2.46 behavior exactly. All
  `tests/configs/*.set` files updated. New ablation config:
  `W1_volregime_on` vs `A2_tuned` at M15, XAUUSD. Status: Candidate,
  pending backtest - see Feature Log F55.

## WiseTrader EA v2.46 — 2026-07-28

### F54 Ehlers cycle weight - campaign verdict recorded
- REJECTED (zero effect): 2026-07-28 campaign - `V1_cycleweight_030` (0.30)
  and `V2_cycleweight_040` (0.40) produced results IDENTICAL to `A2_tuned`
  (0.20) to the cent: net $893.38, PF 1.44, n=106, Sharpe 5.34, all three.
  Root cause: `score` only gates entry via `InpMinScore=0.55`; no setup in
  this window sat in the band the weight change could flip. Underweighting
  hypothesis disproven cleanly. `InpCycleTurnWeight` stays in the EA
  (default 0.20, reproduces pre-v2.46 behavior).

### Added — F54 Ehlers cycle weight now sweepable (was hardcoded)
- The Ehlers `CycleTurn` score bonus in `SignalEngine::Score()` was a
  hardcoded `0.20`; now driven by `InpCycleTurnWeight` (default 0.20, so
  v2.45 behavior is reproduced exactly). Motivation: the cycle signal is
  frequency-domain, not bar-counting like most of the rest of the scorer -
  worth testing whether it's underweighted relative to the information it
  actually carries.
- New sweep configs: `V1_cycleweight_030` (0.30), `V2_cycleweight_040`
  (0.40), both vs `A2_tuned` (0.20) at XAUUSD M15. Status: Candidate,
  pending backtest - see Feature Log F54.

## WiseTrader EA v2.45 — 2026-07-28

### F53 trend-slope - campaign verdict recorded
- REJECTED: 2026-07-28 campaign (`U1_regression_on` vs `A2_tuned`, XAUUSD M15,
  2026.01.01-2026.07.08, model 1) - net profit/expectancy nudged up slightly
  (+6%/+2%) but Sharpe fell 5.34->4.56 (-15%) and max DD ticked up
  (2.94%->3.01%), n=106->110. Same "small in-sample delta, don't trust it"
  pattern the project already learned from E9/S5 - not pursued to model
  4/OOS. `InpUseRegression` stays in the EA (default false).

### Added — F53 trend-slope (OLS regression) confluence score, OFF by default
- New scored input in `SignalEngine::Score()`: OLS slope of closes over
  `InpRegressionLookback` bars (default 30, closed bars only, no lookahead)
  agreeing with the trade direction adds `InpRegressionWeight` (default 0.15)
  to the confluence score, gated on `InpRegressionMinR2` (default 0.30) so a
  flat/noisy window can't falsely claim a trend. New helper
  `CSignalEngine::RegressionSlope()`.
- Motivation: catches grinding, low-volatility trends that never trip a
  clean structure swing break - a different blind spot than F52 (momentum
  acceleration) or structure itself (did price break a level).
- `InpUseRegression=false` (default) reproduces v2.44 behavior exactly. All
  `tests/configs/*.set` files updated with explicit off-defaults. New
  ablation config: `U1_regression_on` (compare vs `A2_tuned` at M15,
  XAUUSD). Status: Candidate, pending backtest - see Feature Log F53.

### F52 momentum - campaign verdict recorded
- REJECTED as default on XAUUSD M15 (the validated deployment setup):
  2026-07-28 campaign vs `A2_tuned` (2026.01.01-2026.07.08, model 1) - PF
  1.44->1.19, expectancy $8.43->$4.01, net $893->$461, Sharpe 5.34->2.19
  (n=106->115). Cause: the score is a pure additive bonus with no penalty
  for misalignment, so on an already-tuned config it only admits more
  marginal trades past `InpMinScore`, diluting quality rather than
  filtering it. Notable but unvalidated side-finding: on M30 (itself an
  unproven timeframe for this strategy - baseline alone loses, PF 0.86) the
  same toggle flipped it to marginally profitable (PF 1.14) - filed as a
  curiosity, not evidence, per Feature Log F52. `InpUseMomentum` stays in
  the EA (default false) for future reference/reuse rather than being
  ripped out - the RSI plumbing itself may be useful for a future filter-
  style (not bonus-style) variant.

## WiseTrader EA v2.44 — 2026-07-24

### Added — F52 momentum (RSI) confluence score, OFF by default
- New scored input in `SignalEngine::Score()`: RSI(`InpMomentumPeriod`, default
  14) agreeing with the trade direction (`InpMomentumLongTh`=55 for longs,
  `InpMomentumShortTh`=45 for shorts) adds `InpMomentumWeight` (default 0.15)
  to the confluence score. Mirrors the existing ADX-handle pattern in
  `SignalEngine.mqh` (`m_rsi_handle` via `iRSI`, released implicitly like
  `m_adx_handle`).
- Motivation: structure/BOS-CHoCH asks "did price break a level"; this asks
  "is the move actually sustained," using a longer smoothed window (14+ bars)
  instead of the last 3-4 candles the swing/structure logic already leans on.
  First of a planned series of movement-signal candidates (F52-F57) requested
  after observing visible chart moves the EA wasn't acting on early.
- `InpUseMomentum=false` (default) reproduces v2.43 behavior exactly - no
  change to the running XAUUSD demo. All 42 existing `tests/configs/*.set`
  files were updated to carry the new inputs explicitly (off-defaults) so no
  config silently falls back to compiled defaults.
- New ablation configs: `T0_baseline_m30`/`T0_baseline_h1` (A2_tuned control
  at M30/H1, momentum off) and `T1_momentum_m15`/`_m30`/`_h1` (momentum on),
  to isolate the feature's effect independent of timeframe. Status: Candidate,
  pending backtest - see Feature Log F52.

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
