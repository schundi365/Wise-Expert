# SwingTrader (H1 trend-following) — Results & Project-Wide Honest Verdict

## What SwingTrader is
The higher-timeframe pivot: the same disciplined, hard-stopped framework as
MomentumScalper, moved to H1 on the theory that gold's larger H1 moves would let
a real edge clear the spread. Entry = Donchian(20) breakout traded only WITH the
EMA 50/200 trend stack + slope. Hard ATR stop, R up to 3, BE + ATR trail, one
position at a time. Magic 77032024.

## What the tests showed

### OHLC sweep (XAUUSD H1, Jan–Jul 2026, 1-min OHLC)
| Config | Net | PF | Trades | Won % | Max DD |
|--------|-----|------|--------|-------|--------|
| A (Don20, R2) | +£398 | 3.80 | 7 | 57% | 1.4% |
| D (Don20, R3) | +£515 | 4.62 | 7 | 57% | 1.3% |
| C (Don20, R1.5) | +£264 | 2.85 | 7 | 57% | 1.4% |
| F (H4) | −£93 | 0.48 | 6 | 50% | 1.8% |

The profit factors *looked* excellent. **But only 7 trades in 6 months — far too
few to trust.**

### Real-tick verification (the decisive test, Mar 20–Jul 24 2026)
- Config D on real ticks: **0 trades** (didn't fill on honest ticks).
- Diagnostic — config D on OHLC over the *same* Mar20–Jul24 window: **2 trades,
  both losers, −£103.**

### Conclusion: SwingTrader did NOT pass
The +£515 / PF 4.62 came from ~5 trades in Jan–Mar, a period with **no real-tick
data to verify against.** In the only window we can check honestly, it made 2
trades and lost. **That is noise, not a proven edge.** A high profit factor on a
handful of unverifiable trades is exactly the kind of number that fools people.

---

## PROJECT-WIDE HONEST VERDICT

Across everything built in this project, here is the truth on **real ticks**
(the only fills that matter, because they're what you get live):

| Strategy | Style | Real-tick result | Verdict |
|----------|-------|------------------|---------|
| **GridHedge** | grid/martingale hedge | −£10k, 99.96% drawdown (wipeout) | Fails. The +£24k was a pure OHLC illusion. |
| **MomentumScalper** | M5 breakout | PF 1.14, +£554/4mo | Marginally positive but too thin to trust live. |
| **MeanReversion** | M5 fade | PF 0.98, slight loss | Fails. No edge. |
| **SwingTrader** | H1 trend | Unverifiable; 2 verifiable trades lost | Fails verification. |

### The single most important lesson
Every strategy looked good on the **1-minute OHLC** backtest and collapsed on
**real ticks**. That gap is the trading cost (spread + slippage + imperfect fills).
On gold at retail spreads, that cost is larger than any edge these methods produce.

- A great backtest is not a great strategy. Only the real-tick result counts.
- A high win rate (the grid's 99%) is meaningless if the losses are unbounded.
- A high profit factor on few trades (SwingTrader's 4.62 on 7) is noise.

### The honest bottom line
**No strategy in this project has a robust, verifiable edge on gold.** The only
marginally-positive one (MomentumScalper, PF 1.14) is too thin to risk real money
on. This is not a failure of any one idea — it is the market telling us that easy,
automated retail edges on gold that clear costs are very hard to find. Months of
work across grid, momentum, mean-reversion, and trend all point the same way.

---

## What is actually worth doing from here

Ranked by honesty, not hope:

1. **Stop looking for the magic EA on gold M5.** The data has answered this. Do not
   run the grid live — the demo of the "£24k" config will show equity trending down
   toward the −£10k real-tick path. Watch it prove itself, then retire it.

2. **If you keep going, change the inputs, not the indicators.** The productive
   experiments left are: (a) test the *same* disciplined framework on instruments
   with lower relative cost (major indices, or FX majors after per-symbol tuning);
   (b) get a longer real-tick history from a live/funded feed rather than a demo,
   so results are actually verifiable; (c) walk-forward testing, never a single
   in-sample sweep.

3. **Accept the realistic outcome.** Consistently profitable automated trading is a
   professional, capital- and infrastructure-intensive pursuit. A retail EA on a
   demo feed clearing costs on gold is the exception, not the rule. The value built
   here is a *disciplined, safe framework* (hard stops, fixed risk, honest testing)
   — reusable, but not a money printer.

## Files
- EA: `src/SwingTrader/SwingTrader.mq5` (compiled, deployed to Vantage + Pepperstone)
- Drivers: `run_sweep_pepper.ps1`, `run_realtick_pepper.ps1`, `run_check_window.ps1`
- Tested on the Pepperstone terminal (separate instance) so it didn't disturb the
  Vantage demo.
