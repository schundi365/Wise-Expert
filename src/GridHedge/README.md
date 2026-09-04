# GridHedge EA

A grid / hedging Expert Advisor modelled on the "JNS Scalp V22" behaviour seen
in your Vantage demo (login 26023332) report and control panel. Standalone —
it shares no code with WiseTrader.

## What it does (v2.00)

- Runs **two independent grids at once** on the chart symbol: a BUY side and a
  SELL side (hedged). This matches the panel's "Opened Buy / Opened Sell".
- Seeds a first position per enabled side, then **adds another position every
  `InpGapPoints` the price moves against that side** (classic averaging grid).
- **Every position carries its own take-profit** (`InpTpPoints`), so each level
  books a small profit on a pullback. This is what produces the high win rate.
- **Trade management (new in v2, matches the JNS behaviour you observed):**
  - **Break-even:** once a position is +`InpBreakEvenPoints` in profit, its stop
    is moved to entry (+`InpBeOffsetPoints`) so a winner can't turn into a loser.
  - **Lock & book:** once a position reaches +`InpLockBookPoints`, it is **closed
    outright** to bank the profit (the "3rd positive closed" you saw), even before
    its own TP.
- Tags positions `P1, P2, ...` by level (like the report's `P1/P2/P5`) and
  isolates them by `InpMagic`.
- **Interactive dashboard (new in v2):** on-chart BUY (blue) / SELL (red) panels
  with editable Lot / Gap / Profit / Lock fields, per-side ON/OFF toggle, +BUY /
  +SELL manual-add and CLOSE-side buttons, a master RUNNING/STOPPED + CLOSE ALL
  strip, and live Levels + P/L + Basket P/L readouts. Edits apply immediately.

## Inputs

**Grid**
| Input | Default | Meaning |
|---|---|---|
| `InpLot` | 0.10 | Lot per grid position |
| `InpGapPoints` | 500 | Distance between levels, in **points**. XAUUSD: 500 pts = $5.00 move (≈ panel "50.0") |
| `InpTpPoints` | 700 | Per-position take-profit, in points (≈ your report's dominant ~70pt→ but note: report TP was in *price*, tune to taste) |
| `InpTradeBuy` / `InpTradeSell` | true | Enable each side |
| `InpMagic` | 26023332 | Isolates this EA's positions |

**Safety (defaults ON — read this section)**
| Input | Default | Meaning |
|---|---|---|
| `InpMaxLevels` | 8 | Max open positions **per side**. `0` = unlimited (**dangerous**) |
| `InpMaxFloatingLoss` | 800.0 | If combined floating P/L ≤ −this (account ccy), flatten & halt. `0` = off |
| `InpEquityStopPct` | 20.0 | If equity drops this % below start, flatten & halt. `0` = off |
| `InpBasketTP` | 0.0 | If combined floating P/L ≥ this, close all (bank the grid). `0` = off |
| `InpCloseAllOnStop` | true | On a safety trip, flatten every position for this magic |

When a **halt** trips (floating-loss or equity stop), the EA stops trading and
latches. **Remove and re-attach** the EA to resume.

## The honest risk — please read

Your own report proves the character of this strategy:

- Win rate **94%**, but **average loss was 5.3× the average win** (−$70 vs +$13).
- At report time there was a **held, averaged ladder floating −$667** that the
  net-profit headline did not include.
- Sharpe ratio **0.12** — poor risk-adjusted return despite the win rate.

That is a **martingale-style averaging grid**. It prints green on ranging days
and gives most/all of it back on a sustained one-way trend, because it keeps
adding losing positions. The 1.14% max drawdown in the report is the *calm-water*
number, not the storm number.

The safety inputs (`InpMaxLevels`, `InpMaxFloatingLoss`, `InpEquityStopPct`) are
the **only** things converting "eventually blows the account" into "loses a
bounded, known amount and stops." They are yours to widen or disable — but if you
turn them off, you have removed the floor. Do that only on demo, knowingly.

## Run it (Vantage demo)

The compiled `GridHedge.ex5` is already in the Vantage install
(`...\Terminal\92518C9899A1ED3884F29F1749EEC361\MQL5\Experts\GridHedge\`).

1. Open the **Vantage MT5** terminal (demo 26023332).
2. Open an **XAUUSD** chart (any timeframe — the EA is tick-driven, not bar-driven).
3. Navigator → Expert Advisors → drag **GridHedge** onto the chart.
   - Common tab: ✅ Allow Algo Trading.
   - Inputs tab: confirm lot/gap/tp and the safety caps.
4. Toolbar **AlgoTrading** button green (🙂 on the chart).
5. Watch the Experts tab — it logs every level open, safety trip, and close.

## Suggested first demo test — find the real risk, not the pretty part

Run it through a **trending** session (a news day: NFP / CPI / FOMC), not just a
quiet range. Watch the peak *floating* drawdown while price runs one direction
and does not come back. That number — not the net profit on calm days — tells you
whether this is viable. Start with the safety defaults ON so a bad run stops
itself instead of running to margin call.

## Dashboard controls (v2)

Two panels appear top-left of the chart when `InpShowPanel = true`.

**Per side (BUY = blue, SELL = red):**
- **Lot / Gap / Profit / Lock** — editable fields. Type a value, press Enter; it
  applies live. (Lot/Gap/Profit/Lock are shared across both sides — editing either
  panel updates both.)
- **SIDE: ON/OFF** — enable/disable *new entries* for that side. Existing positions
  keep being managed.
- **+ BUY / + SELL** — manually add one position to that side right now.
- **CLOSE BUY / CLOSE SELL** — flatten that side.
- **Levels / P/L** rows — live count (n/max) and floating P/L for that side.

**Master strip (below the panels):**
- **RUNNING / STOPPED** — master switch. STOPPED = no new grid entries (management
  still runs). If a safety halt tripped, this shows **HALTED**; click it to clear
  the halt and resume.
- **CLOSE ALL** — flatten everything for this magic.
- **Basket P/L** — combined floating P/L across both sides.

New management inputs:
| Input | Default | Meaning |
|---|---|---|
| `InpBreakEvenPoints` | 300 | Move a position's SL to break-even once it's +this pts (0 = off) |
| `InpLockBookPoints` | 700 | Close a position to bank profit at +this pts (0 = off) |
| `InpBeOffsetPoints` | 10 | Break-even offset beyond entry, points (covers spread) |
| `InpStartRunning` | true | Master START state on attach |
| `InpShowPanel` | true | Draw the dashboard |

## Exit model — reverse-engineered from the JNS results file (v2.1)

The `ReportHistory-26023332.csv` deal data was analysed to match how JNS actually
opens and books, rather than guessing from the panel. Findings and how this EA
now mirrors them:

| Observed in the report | This EA |
|---|---|
| **0 of 398 positions had a broker TP** | Entries are opened NAKED (no TP). Profit is booked in code. |
| Winners' median booked move ≈ **70 points**, closed individually (378 distinct close times) | `ManagePositions()` closes each position in code once it is +`Profit` points — not a resting TP order. |
| **Only ~30% (121/398) ever had an SL**, added late | No SL at entry. The break-even step ADDS the SL only once a position is +`InpBreakEvenPoints`. |
| **7 simultaneous multi-position closes** (up to 6 at once) | `InpSideBasketTP` flattens a whole side at once when its combined floating profit hits the target (the JNS "Target" basket). |
| Big losers ran **−3000 to −6000 points with NO stop** | Same mechanic here — losers are held unstopped. This is the martingale tail; the safety floor (`InpMaxLevels`, `InpMaxFloatingLoss`, `InpEquityStopPct`) is the only thing that bounds it. |

**New / changed inputs for this model:**
| Input | Meaning |
|---|---|
| `InpTpPoints` | Now the **code profit-close** distance (per position), not a broker TP. Default 700 pts; the JNS data clustered ~70 pt price (700 points) — tune to taste. |
| `InpSideBasketTP` | Close one whole side when that side's floating P/L ≥ this (account ccy). `0` = off. |
| `InpLockBookPoints` | Only meaningful if set ABOVE `InpTpPoints` (else the profit-close fires first). |

So the EA now books profit the way JNS does — code-managed per-position closes at
a fixed profit distance, optional whole-side basket close, break-even that adds a
late SL — and it carries the same unstopped-loser risk, held in check only by the
configurable safety floor.

## Basket price target — "book winners, keep top-2 hedge" (v2.2)

Reproduces the JNS panel's `Target` behaviour you described: when price reaches a
side's target level, the EA **closes the profitable positions on that side but
keeps the 2 highest-profit ones open as a hedge**. Losing positions are left
untouched (the ladder continues); the side keeps running.

| Input | Meaning |
|---|---|
| `InpBuyTarget` | BUY side target **price**. When bid ≥ this, book BUY winners but keep the top-N. `0` = off. |
| `InpSellTarget` | SELL side target **price**. When ask ≤ this, book SELL winners but keep the top-N. `0` = off. |
| `InpKeepHedge` | How many highest-profit positions to KEEP open on trigger (default **2**). |

**Exact rule:** on trigger, collect all positions on that side with floating
profit > 0, sort by profit descending, keep the top `InpKeepHedge`, and close the
rest. If a side has `InpKeepHedge` or fewer winners, nothing is booked (there's
nothing beyond the hedge to close).

Example (BUY, `InpBuyTarget=4550`, `InpKeepHedge=2`): price rises to 4550 → the EA
closes every profitable BUY except the 2 with the highest profit, which stay open.
The losing BUYs (if any, from earlier averaging) are untouched.

> Note: this is a **price** trigger (level touched), separate from `InpSideBasketTP`
> (a combined-profit-in-money trigger that flattens the whole side). You can use
> either, both, or neither.

## v3.00 — full JNS-style panel (INTERPRETED control meanings)

The v3 dashboard mirrors the JNS layout. **The meaning of each control is my own
interpretation** of a sensible grid EA, inferred from the panel's abbreviations —
it is NOT decompiled from the JNS binary (that is compiled, packed, and a paid
product; I won't reverse-engineer it). If your JNS behaves differently for any
control, tell me the actual behaviour and I'll change it.

### Per-side buttons (top row)
| Button | Interpreted meaning |
|---|---|
| **ST** | Start — enable new entries for that side |
| **PU** | Pause — stop *new* entries; keep managing/closing existing ones |
| **CL** | Close — flatten that side now |
| **SY** | Sync — re-scan open positions and refresh the panel (recovery view) |
| **RE** (REP) | Report — print that side's levels / floating P/L to the Experts log |

### Per-side fields
| Field | Interpreted meaning |
|---|---|
| **Lot** | Base lot for level 1 |
| **Prot** | Protect — arm break-even once a position is +Prot points in profit |
| **Lock** | Lock-and-book distance (close a runner at +Lock pts; only if > Profit) |
| **B+S** | Break-even step — after Prot arms, trail the stop this many points behind price (0 = static break-even) |
| **Target** | Basket price target — at this price, book the side's winners but keep the top-`InpKeepHedge` (default 2) open as a hedge |

### Grid table (per side): rows Gap2 / Gap3 / Gap4 / ProS
Each level has its **own** parameters, applied to the 2nd, 3rd, 4th, and 5th+
positions respectively:
| Column | Meaning |
|---|---|
| **Gap** | Points the price must move against the side before adding THIS level |
| **Lot** | Lot for this level |
| **Profit** | (display of per-level profit target; profit-close currently uses the base Profit — see note) |
| **Lock** | Per-level lock distance |
| **ON/OFF** | Toggle whether this level is allowed to open |

**ProS** = the 5th-and-beyond level, seeded with a wide (5×) profit target — a
"profit-scalp" tier. Level 1 (the seed) uses the base Lot/Gap/Profit fields.

> Note: per-level Gap / Lot / ON-OFF fully drive entries. Per-level Profit/Lock
> are wired into the table but the profit-CLOSE currently uses the base `Profit`
> for simplicity; say the word and I'll make the close honour each level's own
> Profit/Lock too.

### Master strip + live position table
- **RUNNING / STOPPED / HALTED** master, **CLOSE ALL**, **Basket P/L**.
- **Position table** under the panels: up to 10 open positions with
  `# Side Lot Entry P/L State` (State = OPEN+ / OPEN- / LOCKED).

### New basket input
| Input | Meaning |
|---|---|
| `InpSideSL` | Close a whole side if its floating loss ≤ −this (account ccy; 0 = off) |
