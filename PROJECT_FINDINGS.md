# Wise Trader — Project Findings & Root-Cause Analysis

Honest, evidence-based record of everything tested and what the data actually says.
All conclusions are from **real-tick** back-tests (the only fills that match live
trading). OHLC-model numbers are noted only to show how misleading they were.

---

## The strategies tested (all on XAUUSD unless noted), real-tick verdicts

| # | Strategy | Idea | Real-tick result | Verdict |
|---|----------|------|------------------|---------|
| 1 | **GridHedge** | dual grid + hedge, book greens, let losers float | −£10k, 99.96% drawdown (wipeout) | Fails. |
| 2 | **GridHedge survivable** | grid + hard caps | −£1,500, 74% win | Fails (caps just realize the loss sooner). |
| 3 | **GridHedge + AVS** | asymmetric lot scaling (smaller counter-trend) | −£1,526 capped / −£9,123 uncapped | No help. |
| 4 | **MomentumScalper** | M5 breakout, hard stop, R:R 1.8 | XAUUSD +£554 / basket −£5,337 | Single-symbol luck. |
| 5 | **MeanReversion** | M5 fade Bollinger+RSI | PF 0.98, slight loss | Fails. |
| 6 | **SwingTrader** | H1 Donchian trend | 2 verifiable trades, both lost | Unverifiable / fails. |
| 7 | **TideRider** | multi-market trend, uncapped winners, pyramiding | −£508 basket, 10 trades | Fails. |

Seven distinct approaches. **None profitable on honest fills.**

---

## Root-cause analysis (the "what is actually going wrong")

### 1. The grid family (1–3): a structural, unfixable flaw
The grid produces a very high win rate (74–99%) by booking many tiny green closes
while letting the losing side float **without a per-position stop**. That floating
loss is unbounded. Sooner or later one trend makes it larger than all the banked
green combined, and the basket flushes.
- **This is arithmetic, not tuning.** Caps, scalp mode, and AVS lot-scaling were all
  tested. None fixed it, because none of them adds a stop to the losing side.
- A high win rate with an unbounded loss is a **negative-expectancy** system dressed
  up to look positive. The +£24k "backtest" was a 1-minute-OHLC artifact; on real
  ticks the same config lost the account.

### 2. The directional strategies (4–7): no predictive edge
MomentumScalper looked like our one winner (XAUUSD PF 1.14). The **basket test across
11 instruments killed that hope honestly**:
- XAUUSD was the ONLY symbol with PF > 1. Every other market lost.
- Clean aggregate: **~−£5,337 over ~837 trades, PF 0.46.**
- **Gross profit £13,104 vs gross loss £28,541** — the raw signal loses *before*
  spread/commission is even considered. Gross PF is already 0.46.
- The highest-frequency symbols (XAGUSD 245 trades, GBPJPY 323 trades) lost the most.
  More trades = more loss = the signature of a **negative** edge, not a cost problem.

**Conclusion:** the entries do not predict direction better than chance. The XAUUSD
result was one symbol in one window — luck, confirmed by the basket.

### 3. Cost vs signal — the question we set out to answer
We wanted to know: is the strategy losing because of **cost** (fixable: widen targets,
raise timeframe) or because the **signal has no edge** (not fixable by tuning)?
The gross-before-cost PF of 0.46 answers it decisively: **the signal has no edge.**
Cost makes it worse, but even free trading wouldn't make these strategies profitable.

---

## Bugs found and fixed (on principle — safety regardless of edge)
- **Sizing blowup (XAUGBP):** on symbols with unusual contract specs, the broker's
  minimum lot risked far more than intended (−£10,100 on ONE trade in both
  MomentumScalper and TideRider). Fixed with a hard risk ceiling: if the smallest
  allowed lot would risk > 3× the intended money, **refuse the trade**. Verified:
  XAUGBP now takes 0 trades instead of blowing up. Both EAs are now safe.
- **Rollover rejects:** entries at the daily close were rejected "market closed".
  Fixed with a rollover-hour guard.
- **Entry-logic regression:** a loosened breakout entry quadrupled trades and
  destroyed the edge; reverted to the strict live-break with a configurable mode.
- **ATR handle leak (AVS draft):** the user's draft created/released an ATR handle
  every tick. Fixed by caching the handle once in OnInit.

---

## The honest bottom line

Across **7 strategies and 11 instruments**, on real-tick data, there is **no robust,
verifiable edge.** This is not a failure of any single idea or of effort — it is a
consistent signal:

> **Simple price-indicator EAs, optimized on a demo feed, do not have a directional
> edge that survives honest fills.** This is the most-crowded, most-arbitraged corner
> of trading. The strategies that *do* work for professionals rely on advantages we
> don't have here: institutional cost structures, speed/infrastructure, genuinely
> alternative data (order flow, fundamentals), or scale across hundreds of markets.

### What is NOT true
"Markets are unbeatable." False — they are beaten consistently by those with a real
edge input. What's true is narrower: **this particular method (retail price EAs) is a
known dead end**, and every attempt in this project to force it (more frequency,
hedging, riding harder, asymmetric sizing, diversification) either did nothing or
increased the risk of ruin.

### What was actually built of value
A disciplined, safe, honestly-tested framework: fixed risk, hard stops, real-tick
verification, portfolio testing infrastructure, and sizing safety guards. That is
reusable and is more than most retail attempts ever produce — it just isn't a money
printer, and no honest test could make it one.

### Recommended next steps (ranked by honesty)
1. **Stop searching for the winning price-indicator EA.** The evidence is conclusive.
2. If continuing: pursue a real **edge input** — alternative data, a genuinely lower
   cost structure (professional/prop), or a structural/mechanical edge (carry,
   funding-rate, rebalancing flows) — not another chart-pattern combo.
3. Treat profitable automation as a multi-year, capital- and data-intensive pursuit,
   or decide the time/capital is better spent elsewhere.

---

## Testing method notes (so results are reproducible)
- Real-tick data on the demo feeds begins **2026-03-20**, so the honest window is
  Mar–Jul 2026. Anything earlier is OHLC-only and unverifiable.
- Tests run headless via `terminal64.exe /config:<ini>`; results parsed from the
  `.htm` report. Model=4 = real ticks (trust this), Model=1 = 1-min OHLC (optimistic).
- The **Pepperstone** install was used for testing so the **Vantage** demo could run
  undisturbed. Drivers live in each EA's `src/<EA>/` folder.
