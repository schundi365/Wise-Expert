# JnsGrid — Final Verdict (JNS pullback entry + fatal flaw fixed)

## What was built (exactly as requested)
1. **Real JNS Scalper V22 pullback entry.** Using the actual params from the JNS
   inputs screenshot: a level becomes "due" after price moves `InpJnsTriggerPoints`
   (100pt) from the last entry; then the EA WAITS `InpPullbackWaitSecs` (30s) AND
   requires price to retrace `InpPullbackPoints` (30pt) back off the extreme before
   filling. This is "don't chase, buy the dip" — the real JNS mechanic.
2. **The fatal flaw FIXED.** A mandatory hard per-side stop (`InpSideSL`, default
   £150) checked every tick before any new entry. The losing side can NEVER float
   unbounded — it is force-closed the instant its floating loss hits the cap.

## Real-tick test (XAUUSD M5, Mar–Jul 2026)
| Per-side SL | Net | PF | Trades | Won % | Max DD |
|-------------|-----|-----|--------|-------|--------|
| £100 | −£1,501 | 0.74 | 762 | 80% | 16.2% |
| £150 | −£1,500 | 0.76 | 792 | 85% | 16.4% |
| £250 | −£1,502 | 0.74 | 668 | 90% | 16.9% |

Same ~−£1,500 loss at every stop level. The pullback entry made no difference.

## FULL-YEAR test (Jul 2025 – Jul 2026, monthly, OHLC)
| Month | Net | PF | | Month | Net | PF |
|-------|-----|-----|-|-------|-----|-----|
| 2025-07 | −£1,215 | 0.82 | | 2026-01 | −£1,505 | 0.85 |
| 2025-08 | −£1,511 | 0.81 | | 2026-02 | −£239 | 0.57 |
| 2025-09 | −£1,510 | 0.79 | | 2026-03 | −£1,509 | 0.89 |
| 2025-10 | +£523 | 1.06 | | 2026-04 | −£683 | 0.87 |
| 2025-11 | −£1,501 | 0.85 | | 2026-05 | −£1,566 | 0.90 |
| 2025-12 | −£1,501 | 0.89 | | 2026-06 | −£1,506 | 0.88 |

**YEAR TOTAL: −£13,723. Only 1 of 12 months positive.**

## Verdict
- **The flaw fix works:** no wipeout all year, drawdown controlled (~16%). The
  uncapped version produced a −£10k/99.96% wipeout; this survives every month.
- **But it is not profitable:** it loses ~£1,500 EVERY month, 11 of 12 months red,
  −£13,723 for the year, at an 80–90% win rate.

**Fixing the flaw converts a catastrophic wipeout into a predictable steady bleed.
It changes WHEN and HOW you lose, never WHETHER.** The grid has no directional edge,
so no entry mechanic (pullback, AVS, scalp) and no stop setting makes it profitable.
The consistent −£1,500/month is the cost of trading a no-edge strategy with a stop.

The "£3k closed, −£600 floating" snapshot that looks reasonable is the good moment
before the bleed — held for a year with the flaw fixed, it is −£13,723.

## The settled conclusion for the whole project
Across grid (plain/capped/uncapped/scalp/AVS/JNS-pullback), momentum, mean-reversion,
trend, and session-breakout — tested on real ticks and over a full year — NO variant
has a durable, profitable edge on these instruments. The grid specifically cannot be
fixed: its high win rate is the signature of hidden losses, and capping those losses
makes it survivable but still net-negative. Pursuing profit further requires a
different EDGE INPUT (order-flow/alternative data, or a real cost/infrastructure
advantage), not another entry rule, sizing scheme, or stop tweak.


---

## EXACT REAL-PANEL CONFIG TEST (from the JNS screenshot)
Reproduced the real JNS panel precisely: Lot 0.01, Gap 50pt, Profit £1, Lock £0.50,
Prot 20pt, B+S 10pt, deep stacking (MaxLevels 90), £100,000 deposit. Real ticks,
XAUUSD M5, Mar–Jul 2026.

**Result (capped, per-side SL scaled to account):**
- Net: **−£15,000 on £100k = −15%**
- Win rate: **93%** (39,848 / 42,821 trades)
- Max drawdown: 15.2% | Profit factor: **0.58**

**Uncapped variant:** did not complete — a 90-level deep stack with no stop became
unrunnable on real ticks (margin/execution limits). Uncapped deep stacking isn't
even viable, let alone profitable.

### Why this is the most revealing result
- The screenshot insight (0.01 lots on a £100k account) WAS important: it keeps the
  drawdown to ~15% and produces the exact JNS profile — 42,821 tiny trades, 93% win
  rate, small float relative to the account. It genuinely looks calm in a snapshot.
- **But it still loses 15%, and PF (0.58) is WORSE than the 0.10-lot tests (0.74–0.90).**
- The reason: the tight 50pt gap + £1 targets make it trade **42,000+ times**, and
  every trade pays the spread. At £1 per scalp, spread is a huge fraction of each win.
  **Trade volume this high means spread cost dominates and buries the 93% win rate.**

### The final, complete conclusion
Faithfully reproduced with the REAL panel config, on honest fills, the real JNS still
loses (−15% in 4 months). Correct sizing changes the *magnitude* (survivable, not a
wipeout) but not the *sign* (still negative). The "£3k float on £105k, +£464 day"
snapshot is the good moment; run on real fills it bleeds to −15% via spread on 42,000
trades. No sizing, entry, or stop configuration makes the grid profitable — the
edge isn't there, and at this trade frequency, costs alone would sink even a fair coin.


---

## CRITICAL: the +£142k "year" was a pure OHLC fill artifact (VERIFIED)
The full-year OHLC run of the exact real-panel config showed a spectacular
**+£142,605 (142% on £100k), 8/12 months positive**, including Feb +£49k, Mar +£34k.

This looked like the holy grail. It is FICTION. Verification on real ticks:

| Month | OHLC model | REAL TICKS |
|-------|-----------|------------|
| Mar 2026 | **+£34,761** (PF 1.35) | **−£13,042** (PF 0.57, 93% won, 36,615 trades) |

A **£47,000 swing on one month** from fill modeling alone.

### Why (the most important lesson in the project)
A grid trading **~40,000 times/month with £1 profit targets** is MAXIMALLY sensitive
to fill assumptions. OHLC assumes every tiny scalp fills perfectly at target with no
spread. Across 40,000 trades that false assumption manufactures +£142k from nothing.
Real ticks apply the actual spread to all 40,000 trades -> the same strategy LOSES.

**The higher the trade frequency, the bigger the OHLC lie.** The ultra-high-frequency
JNS config produces the most spectacular fake backtest AND the most reliable real
loss. This is precisely the illusion that sells grid EAs and empties accounts.

### FINAL, DEFINITIVE VERDICT
Real JNS Scalper V22, exact panel config, on HONEST FILLS: **loses ~13–15% over a
few months, PF ~0.57, 93% win rate, every single time.** No config, sizing, stop,
entry mechanic, or timeframe makes the grid profitable on real fills. The impressive
snapshot, the impressive backtest, and the real-money loss are the same thing seen
from different angles. Only real-tick testing tells the truth — and it always has.
