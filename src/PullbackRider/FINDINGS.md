# PullbackRider — findings

A clean, single-position trend-following pullback EA. **No grid, no martingale, no
averaging, no opposite-side hedge.** At most one position open at a time, defined risk,
ATR-based stop, and either an ATR trailing stop or a fixed R take-profit.

## Why it exists

Every grid/martingale variant tested in this project (GridHedge, JnsGrid, GridHedgeAVS)
loses on honest fills. The pattern is always the same:

- OHLC backtests look spectacular (JnsGrid tight config showed **+£91k / PF 1.99** on a
  full year, ~99,000 trades) because OHLC modeling fills every tiny scalp at a perfect
  price with zero spread.
- The **same config on real ticks (Model=4) collapses to −£1,500 / PF 0.68**, because the
  spread is charged on every one of thousands of tiny scalps. OHLC filled ~98,000 trades;
  real ticks filled ~7,400. The rest were phantom.

We proved the grid has **no directional edge**: its long-run expectancy per trade is
approximately −(spread + commission). Widening the gap makes each win bigger but the win
rate collapses by exactly enough to keep PF just under 1.0 (0.92–0.96 across every config).
A trend filter on the grid made it *worse*, because the grid adds on pullbacks (buying the
dip) which conflicts with a trend filter that says only buy in uptrends.

PullbackRider is the honest expression of "buy the dip in an uptrend": ONE bet, defined
risk, let the trend pay, cut fast if wrong. It cannot be expressed as a symmetric grid.

## Edge idea

1. **Trend filter** — slow MA (default EMA200) on a higher timeframe must be sloping and
   price on its trend side.
2. **Pullback entry** — wait for price to pull back to a fast MA (default EMA20), then enter
   ONE position when the last closed bar resumes in the trend direction.
3. **Risk** — initial stop = k·ATR. Position sizing from risk-% of equity (authoritative;
   MaxLot is only a safety cap, never rounds up into more risk). A min-stop floor prevents
   a tiny ATR from inflating the lot.
4. **Exit** — either an ATR trailing stop, or a fixed R take-profit, plus optional
   break-even move at +1R.

## Real-tick results (XAUUSD, Model=4, 2026-03-20 → 2026-07-24, £10k, risk 0.5%)

| Config | Setup | Net | PF | Trades | Win% | AvgW / AvgL | Max DD |
|---|---|---|---|---|---|---|---|
| B0 | EMA200 H1 / EMA20 M15, trail 2.5× | −£1,418 | 0.94 | 419 | 47% | 119 / 113 | 32% |
| B1 | same, tight trail 1.5× | −£338 | 0.99 | 617 | 38% | 114 / 70 | 26% |
| B2 | EMA100 H1, trail 3.0× | −£2,597 | 0.89 | 386 | 48% | 117 / 123 | 44% |
| **B3** | **EMA200 H4 / EMA20 H1, trail 2.5×** | **+£2,751** | **1.25** | 100 | 51% | 273 / 228 | 30% |
| **B4** | **EMA200 H1 / EMA20 M15, fixed 2R TP** | **+£2,035** | **1.08** | 427 | 51% | 132 / 126 | 14.8% |

**B3 and B4 are net-positive on REAL TICKS** — the first genuine (non-OHLC-illusion) edge
of this kind in the project.

- **B3**: higher timeframes (H4 trend / H1 entry) cut through the spread noise that sank the
  M15 versions. Best PF (1.25) but only 100 trades = low sample.
- **B4**: fixed 2:1 reward:risk take-profit. Best drawdown (14.8%), more trades (427).

## Honest caveats (READ BEFORE TRUSTING)

- This is **not** the mythical $142k. That number is an OHLC fill artifact and does not
  survive real ticks. Real result here is ~£2k on £10k over 4 months (~5–7%/quarter).
- **Sample is small.** Real-tick data only reaches back to 2026-03-20 (~4 months). B3 has
  only 100 trades. A positive 100-trade result can still be luck.
- Requires out-of-sample validation before any real money: full-year OHLC sanity check,
  real-tick split-half consistency, and ideally another symbol or two.

## Sizing fix (applies to this EA)

Original bug: a MaxLot ceiling overrode risk-% sizing, producing 2.8–3.4% risk/trade and
48–99% drawdowns. Fixed so risk-% is authoritative, MaxLot only caps (never rounds up into
more risk), the trade is skipped if the broker min-lot would over-risk >1.5×, and a
minimum-stop-distance floor stops a tiny ATR from inflating the lot.
