# GridHedge — Test Guide

How to test the GridHedge EA properly, in two stages: **Strategy Tester
(backtest)** first, then **live demo (forward test)**. For a grid/martingale EA
the goal of testing is NOT to confirm it makes money on good days — it always
will. The goal is to find the **worst-case drawdown** before real money does.

Files:
- Source: `src/GridHedge/GridHedge.mq5`
- Compiled: `...\Terminal\92518C9899A1ED3884F29F1749EEC361\MQL5\Experts\GridHedge\GridHedge.ex5` (Vantage install)

---

## Stage 0 — Before you start

- Use the **Vantage demo (login 26023332)** — never a live/funded account.
- Symbol: **XAUUSD**. The EA is tick-driven, so chart timeframe doesn't matter
  for logic (use M1 or M5 so you can watch it).
- Confirm the account is **Hedging** (both buy & sell must coexist). The EA prints
  a warning in the Experts log if it isn't.
- Points reminder for XAUUSD: **10 points = $0.10 of price**. So `InpGapPoints=500`
  = a $5.00 move between levels; `InpTpPoints=700` = $7.00 profit target per
  position. Adjust these to match how the JNS panel behaved (panel "Gap 50.0"
  ≈ `InpGapPoints=500`).

---

## Stage 1 — Strategy Tester (backtest)

Backtests a grid FAST across months, so you can see how it behaves in trends.
Treat the result as directional, not gospel (the tester models spread; real
grids suffer more from slippage and requotes).

### Run it
1. Vantage MT5 → **View → Strategy Tester** (Ctrl+R).
2. **Expert:** `GridHedge`.
3. **Symbol:** XAUUSD.  **Period:** M1.
4. **Model:** "Every tick based on real ticks" (grids are tick-sensitive — OHLC
   models lie about intrabar fills). If real ticks aren't available, use "Every tick".
5. **Date range:** pick at least one **strong trending** stretch, not just a
   quiet month. Good stress windows: a month containing an NFP/CPI/FOMC spike, or
   any period where gold ran several hundred dollars one direction.
6. **Deposit:** match your demo (e.g. 100000 USD), **Leverage:** as per broker.
7. Set inputs (start with defaults + safety ON). Run.

### What to read in the tester report — in priority order
1. **Balance Drawdown Maximal (%) and Equity Drawdown Maximal (%).** For a grid,
   **equity drawdown is the number that matters** — it captures the floating pain
   of the open ladder, which balance drawdown hides. If equity DD is large, the
   strategy is fragile no matter how green the profit is.
2. **Did it ever hit a safety halt?** Search the Journal tab for `HALTED`,
   `MAX FLOATING LOSS`, or `EQUITY STOP`. If yes — good, the floor worked; note
   how much it lost when it tripped. If it blew the account *without* tripping,
   your caps are too loose.
3. **Largest loss / worst basket.** Look for the deepest single dip in the equity
   curve graph. That is your realistic "bad day" size.
4. Profit factor, win %, net — read these LAST. They look great by design; they
   are not what tells you if it's safe.

### Sweep to understand the tradeoff (optional but valuable)
Run the same window 2–3 times changing ONE input:
- `InpGapPoints` wider (e.g. 800) vs tighter (300) — wider = fewer levels, slower
  bleed, but slower profit.
- `InpMaxLevels` 4 vs 8 vs 12 — directly controls worst-case exposure.
- `InpMaxFloatingLoss` 400 vs 800 vs off — see how the halt changes the DD.

The point of the sweep: **find the settings where the worst equity drawdown is a
number you could actually stomach**, then trade those.

---

## Stage 2 — Live demo (forward test)

The real test. Backtests can't reproduce live spread widening and slippage, which
is exactly where a grid gets hurt.

### Attach it
1. Open Vantage MT5 (demo 26023332). Open an **XAUUSD M1** chart.
2. Navigator → Expert Advisors → drag **GridHedge** on. (Refresh if not listed.)
3. Common tab: ✅ Allow Algo Trading. Inputs tab: confirm lot/gap/tp + safety caps.
4. Toolbar **AlgoTrading** green (🙂 on chart).
5. Experts tab should show the `[GridHedge] init ...` line with your settings.

### What to watch (this is the whole point)
- **Peak floating drawdown during a TREND.** Let it run through a news event or a
  clear directional day. Watch the Toolbox → Trade tab: total floating P/L and how
  many `P#` levels stack up on the losing side. THIS number is the verdict.
- **Whether a safety halt fires**, and how much was lost when it did. That is your
  bounded worst case in live conditions.
- **Spread behaviour at levels** — around news, spread on gold blows out; note if
  levels open at bad prices or TPs get skipped.

### Run it long enough
- A grid on 2 calm days looks perfect (your report was exactly that: +3.3%, 1.14%
  DD — but a −$667 ladder was already floating). **Run it at least 1–2 weeks**,
  including a weekend gap and a news day, before drawing any conclusion.

---

## Pass / fail bar (suggested)

Decide these numbers BEFORE testing, then hold to them:

| Metric | Watch | Reject if… |
|---|---|---|
| Max equity drawdown | tester + live | > the % you'd tolerate on real money |
| Worst floating basket | live, during a trend | grows without the safety halt catching it |
| Safety halts | Journal / Experts log | account bleeds past your cap without halting |
| Recovery after a halt | live | it can't recover the halted loss in reasonable time |

If it survives a trending week on demo with equity drawdown inside your limit and
the safety floor doing its job — *then* it's earned a longer demo run. Not before.

---

## Quick troubleshooting
- **No trades open:** AlgoTrading not green, or account not Hedging, or symbol
  isn't XAUUSD. Check the Experts log for the init/warning line.
- **Only one side trades:** `InpTradeBuy`/`InpTradeSell`, or non-hedging account
  netting the two sides.
- **EA stopped and won't trade:** a safety halt latched (see Experts log for
  `HALTED`). Remove and re-attach the EA to resume.
- **Levels don't add:** price hasn't moved `InpGapPoints` against the side yet,
  or `InpMaxLevels` reached.

---

## v2 additions — testing the dashboard + management

**Dashboard checks (live demo):**
- After attaching with `InpShowPanel=true`, confirm the BUY (blue) and SELL (red)
  panels appear top-left, plus the master strip.
- Edit a field (e.g. Gap), press Enter — the Experts log prints `panel edit: ...`
  and the new value takes effect on the next add. Both panels mirror the value.
- Click **SIDE: ON/OFF** — the button flips colour and that side stops opening new
  levels (existing ones keep being managed).
- Click **+ BUY / + SELL** — one position opens immediately.
- Click **CLOSE BUY / CLOSE SELL / CLOSE ALL** — positions flatten.
- Click **RUNNING/STOPPED** — master toggle; STOPPED halts new entries only.
- Trip a safety stop (set `InpMaxFloatingLoss` low and let it run) — the strip
  should show **HALTED**; clicking it clears the halt and resumes.

**Break-even + lock-and-book checks:**
- Set `InpBreakEvenPoints` small (e.g. 100) so it arms quickly. When a position
  goes +100 pts, watch the Experts log for `break-even SL -> ...` and confirm the
  position's SL in the Trade tab jumps to ~entry.
- Set `InpLockBookPoints` (e.g. 200). When a position reaches +200 pts, the log
  prints `LOCK+BOOK closed at +... pts` and the position closes even though its
  fixed TP wasn't hit — this reproduces the "3rd positive closed on lock" you saw.
- Note the interaction: a position can be (a) closed by lock-book, (b) closed by
  its own TP, or (c) protected at break-even if it pulls back after arming. That
  three-way behaviour is exactly the JNS management you described.
