# WiseTrader → Gem Trader: Feature Handoff

A portable list of the features implemented in **WiseTrader** (rule-based
autonomous MT5 bot, currently v2.53, trading market-structure breakouts on
XAUUSD/metals), written as capabilities and design ideas for another bot
("Gem Trader") to consider implementing.

This is a description of *what each feature does and why*, not WiseTrader's
source code. Reimplement the ideas cleanly.

> Legend: **[proven]** = in the deployed/validated baseline;
> **[candidate]** = implemented but not promoted (tested, see notes).

---

## Core signal engine  [proven]

- **Market structure detection** — fractal swing highs/lows, Break of
  Structure (BOS, continuation) and Change of Character (CHoCH, reversal),
  with duplicate-signal suppression (a new confirmed swing must form between
  breaks).
- **Quasimodo (QM) reversal pattern** — a second signal source alongside
  structure breaks.
- **Confluence scoring (0..1)** — combines base signal weight + volume-profile
  proximity + VWAP side + Ehlers cycle turn + ADX trend strength into a single
  score, gated by a minimum threshold. Each setup carries a human-readable
  "evidence" string for the journal.
- **Volume profile** — POC/VAH/VAL levels; entries near a defended node score
  higher.
- **Session VWAP** — trade-side confirmation.
- **Ehlers cycle (Even Better Sinewave)** — rewards entering while the cycle
  turns *with* the trade and isn't already extended.

## Entry quality gates  [proven — these carry the edge]

- **F10 relative-volume gate** — compares the signal bar's volume to the same
  time-of-day bar over prior sessions; rejects breaks without participation
  (the classic fake-break). One of the highest-impact filters.
- **F16 outlier bar mask** — modified Z-score (median/MAD on true range) masks
  news/flash candles so a freak bar can't create a fake signal or skew ATR.
- **Max-chase veto + retest logic** — refuses to buy an over-extended break;
  waits for a pullback to the level. CHoCH always waits for the retest.
- **ADX chop stand-down** — optional; blocks breakouts in low-trend regimes.
- **Minimum stop distance (ATR floor) + minimum reward:risk** validated on
  every setup.
- **F58 spread Z-score gate** *(candidate)* — vetoes entries when the current
  spread is an outlier-high vs its rolling baseline ("toxic flow").
  **Especially relevant for gems/metals**, where spreads blow out around news
  and rollover.

## Risk management  [proven — the survival layer]

- **Broker-exact position sizing** via `OrderCalcProfit` (handles contract
  size, tick value, account-currency conversion — avoids the ~10x oversizing
  that naive tick-value math causes on gold).
- **Volatility-scaled risk** — ATR14/ATR100 regime scalar (optional).
- **Gap buffer** — sizes as if the stop fills beyond the placed SL, using the
  worst recent open gap.
- **Hard limits with veto power over all entries:** daily-loss cutoff,
  total-drawdown hard stop (flatten + permanent lock), consecutive-loss streak
  lock.
- **Restart-safe state** — risk counters persist in terminal global variables
  keyed by magic + account + symbol, so a restart or account switch can't reset
  limits or leak state between accounts.

## Trade management  [proven]

- ATR trailing **and** structure trailing (behind last confirmed swing).
- Breakeven trigger (R-multiple or ATR), with **partial close** at the trigger.
- Profit-locking stop (lock X% of open profit past a threshold).
- TP capping (max TP distance in ATR).
- **Protective flatten** — close before high-impact news and before the
  weekend (Friday flatten). Weekend-gap protection tested net-positive.

## Execution modes  [proven]

- Three break-entry modes: M15-close confirmation, M1-close (~1 min latency),
  or resting stop-order at the level (instant fill, no confirmation).
- Resting **limit order at the retest price** as an alternative to bar-close
  touch.

## Engine architecture  [proven — worth copying wholesale]

- **Non-blocking tick path**: OnTick does trade management only (microseconds)
  plus a time-budgeted slice of analytics.
- **Cooperative scheduler** with per-tick/per-timer microsecond budgets; heavy
  features (VWAP, volume profile, Ehlers) update incrementally and finish on a
  1-second timer, never stalling ticks.
- **Buffered journaling** — CSV writes buffered in memory, flushed on the
  timer, never on the tick path. Full decision/veto traceability.
- **Per-symbol parameter overrides** — one compiled EA, tuned params selected
  per symbol.
- **Multi-timeframe indicator priming (F57 fix)** — in a single-symbol
  backtest, prime the higher-TF history with `CopyRates` *before* creating the
  indicator handle; the tester only builds a secondary timeframe once the EA
  accesses it (otherwise the handle fails with error 4805 for the whole run).

## News / calendar  [proven]

- **F18 economic-calendar blackout** — blocks new entries in a ± window around
  high-impact events for the symbol's currencies.

## Candidate features — implemented but NOT promoted

Tested, did not beat the out-of-sample baseline. Listed so Gem Trader knows
which "good ideas" already failed here and can weigh whether to retry:

- **F52 momentum (RSI) confluence** — rejected (diluted returns).
- **F53 trend-slope (OLS regression) confluence** — rejected (worse Sharpe).
- **F54 Ehlers cycle weight sweep** — rejected (zero effect).
- **F55 volatility-regime (ATR expansion) confluence** — real in-sample edge
  but only parity out-of-sample; not promoted.
- **F56 persistence (variance-ratio) confluence** — rejected.
- **F57 multi-timeframe (H1) agreement** — now works after the priming fix;
  needs a real backtest for its first verdict.
- **F58 spread gate** — newest; pending its first backtest.

## Tooling (not EA features)

- Headless regression campaign runner, ablation `.set` configs, Walk-Forward
  Efficiency scorer for overfit detection, CI enforcing version/changelog
  consistency.

---

## Priority recommendation for a gem/metals bot

Given gold's volatility and spread behavior, prioritize the **proven** survival
and execution-cost features first:

1. **Broker-exact position sizing** (`OrderCalcProfit`) — prevents catastrophic
   oversizing on gold.
2. **Hard risk limits with restart-safe state** — daily loss / total drawdown /
   streak locks that survive restarts.
3. **F58 spread gate** — directly addresses metals' spread blowouts.
4. **F16 outlier bar mask** — metals see frequent freak candles on news.
5. **Protective flatten** (news + weekend) — gap protection.

The confluence-scoring candidates (F52–F57) are lower priority: none beat the
baseline in WiseTrader's testing, so treat them as optional experiments rather
than expected wins.
