# WiseTrader — Autonomous MT5 Bot (Phase 1 MVP)

Rule-based autonomous Expert Advisor built from the *Wise Trader Build Specification v1.0*.
Signals: market structure (BOS/CHoCH) and Quasimodo reversals, scored by confluence with
session VWAP, session volume profile (POC / Value Area), and the Ehlers Even Better Sinewave
cycle. A discipline FSM authorizes trades; a risk manager with hard limits sizes and vetoes them.

## Install

1. In MT5: **File → Open Data Folder**.
2. Copy the whole `WiseTrader` folder into `MQL5\Experts\` (so you get
   `MQL5\Experts\WiseTrader\WiseTrader.mq5` and `MQL5\Experts\WiseTrader\src\...`).
3. Open `WiseTrader.mq5` in MetaEditor and press **F7** (Compile). Zero errors expected.
4. Attach to a **XAUUSD M15** chart (defaults are tuned for it). Enable **Algo Trading**.
5. **Test in the Strategy Tester and on a demo account first. Do not attach to a live
   account until it has run at least 4 weeks unattended on demo.**

## Non-blocking design (why it stays fast)

| Concern | Mechanism |
|---|---|
| Analytics stalling ticks | Cooperative scheduler (`Scheduler.mqh`): VWAP, volume profile and Ehlers update in small chunks under a microsecond budget per tick (default 3 ms); leftovers finish on the 1-second timer. |
| File IO on tick path | Journal buffers in memory; disk flush happens on the timer only. |
| Session rebuild after restart | Feature modules walk M1 history incrementally (300 bars per slice), never in one blocking loop. |
| Trade management latency | `OnTick` runs equity guards + position management first; both are O(open positions) with no file/history calls. |
| Restart recovery | Risk counters (daily equity anchor, loss streak, peak equity, locks) persist in terminal global variables; breakeven/trailing state is inferred from broker-side stops — nothing to lose in a crash. |

## Risk defaults (Moderate profile, personal live account)

- 1% risk per trade, sized from stop distance and tick value
- 3% max daily loss → new-entry lock until next server day
- 10% max total drawdown from peak equity → **flatten all + permanent lock**
  (clear by deleting the `WT_<magic>_<symbol>_lock` global variable — deliberate manual step)
- Max 3 consecutive losses/day → entry lock; max 1 position; min RR 1.5
- Stop floor 1.5×ATR(14); breakeven at 1R; 2×ATR trailing

## Files

- `WiseTrader.mq5` — wiring, inputs, tick/timer/transaction handlers
- `src/Config.mqh` — shared enums/structs/settings
- `src/Scheduler.mqh` — time-budgeted cooperative job scheduler
- `src/Journal.mqh` — buffered CSV journal (in `MQL5\Files\WiseTrader_<sym>_<magic>.csv`)
- `src/M1Walker.mqh` — incremental M1-history walker base
- `src/Vwap.mqh`, `src/VolumeProfile.mqh`, `src/Ehlers.mqh` — feature engine
- `src/Structure.mqh`, `src/Quasimodo.mqh`, `src/SignalEngine.mqh` — signals + confluence
- `src/Discipline.mqh` — setup lifecycle FSM + CanTrade()
- `src/Risk.mqh` — sizing, daily/total DD, streak locks (restart-safe)
- `src/Execution.mqh` — order execution with retries; breakeven/ATR/structure trailing

## Known Phase-1 simplifications (per spec roadmap)

- Volume profile is built from M1 tick volume distributed across bar ranges, not raw ticks
  (removes the broker tick-cache dependency; Phase 2 swaps in `CopyTicksRange`).
- No regime classifier yet — Phase 2 adds the six-label classifier and regime routing.
- Persistence is global-variable based; Phase 2 moves to SQLite with full recovery validation.
- Market entries only (no limit-order pullback entries).
- Single symbol per chart instance.

## Web dashboard (WiseTrader Console)

A GEM-style Flask console lives in `..\..\..\Console\` (Wise Trader\Console):

1. `start_console.bat` (installs Flask + MetaTrader5 pkg, opens http://127.0.0.1:5088)
2. Shows: EA alive/paused/lock state, equity vs day-start/peak, setup FSM, trend,
   VWAP/POC/cycle, open positions, 30-day win rate and net P&L, and a live
   journal feed with severity filters.
3. Controls: **Pause / Resume / Flatten / Clear lock** — sent through a command
   file in `Common\Files` that the EA polls every second (acknowledged in-app).

The EA must be running on a chart for the console to show live data. The console
never places trades itself; the EA remains the single execution authority.

## Disclaimer

Engineering deliverable, not financial advice. Automated trading can lose capital.
Backtest, then demo, then minimum lots — in that order.
