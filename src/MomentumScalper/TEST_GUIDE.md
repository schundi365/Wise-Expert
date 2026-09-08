# MomentumScalper — Strategy, Test Results & How to Run

A positive-expectancy momentum breakout scalper for MT5. Built as the replacement
for the GridHedge / JNS-style grid, which had **negative expectancy** (small capped
wins, unbounded losers that eventually flush the account in one move).

The core difference: **every trade here has a hard stop-loss, and wins are larger
than losses (reward:risk > 1).** A single trend cannot wipe the account.

---

## 1. How the strategy works

**Entry** — momentum breakout with a volatility gate:
- Go **long** when Ask breaks above the highest high of the last `InpBreakoutBars`
  closed bars (plus a `InpBufferPoints` noise buffer). Mirror for **short**.
- Optional EMA trend filter (`InpUseEmaFilter`) — tuned **OFF** (it cut good M5 trades).
- Volatility gate (`InpAtrMinPips`) — skip dead markets. On gold M5 the ATR is almost
  always above the gate, so it rarely binds; it matters more on quieter symbols.
- Rollover guard (`InpAvoidRollover`) — no new entries during the daily close hour,
  which previously caused "market closed" order rejects.

**Exit / management** — the part the grid never had:
- Hard **stop-loss** = `ATR × InpStopAtrMult` (default 1.5×ATR).
- **Take-profit** = stop distance × `InpRewardRatio` (default 1.8 → win 1.8× the risk).
- **Break-even** move once profit reaches `InpBeTriggerR` (1R), locking `InpBeLockPips`.
- **ATR trailing** stop after break-even (`InpTrailAtrMult`) to ride runners.
- The stop is only ever **tightened**, never widened.

**Risk sizing** — position size is derived from `InpRiskMoney` and the stop distance,
so the money risked per trade is **constant** regardless of ATR/volatility.

**Guards** — daily loss stop (`InpDailyLossStop`) halts new trades for the day; spread
guard; one position at a time; at most one entry per bar.

> **Do NOT set `InpOneTradePerBar=false`.** Testing showed re-entry with no per-bar
> throttle over-trades catastrophically (604 trades, -£6,423, PF 0.75). One-per-bar
> is essential to the edge.

---

## 2. Test results (XAUUSD, £10,000 deposit)

### 2a. Parameter sweep — M5, Jan–Jul 2026, **1-minute-OHLC model** (fast, optimistic)

| ID | Bars | ATR gate | EMA | Net £ | PF | Trades | Won % |
|----|------|----------|-----|-------|------|--------|-------|
| A  | 10 | 4 | off | +1,116 | 1.81 | 49 | 59.2% |
| **B** | **7** | **4** | **off** | **+1,252** | **1.75** | **59** | **59.3%** |
| C  | 14 | 4 | off | +1,102 | 2.07 | 41 | 63.4% |
| D  | 10 | 3 | off | +1,116 | 1.81 | 49 | (== A) |
| E  | 10 | 6 | off | +1,116 | 1.81 | 49 | (== A) |
| F  | 10 | 4 | **on** | +837 | 2.10 | 31 | 64.5% |
| G  | 7 | 3 | off, **re-entry ON** | **-6,423** | 0.75 | 604 | 39.7% |

Learnings: ATR gate 3/4/6 gave identical results (not binding on gold M5); the EMA
filter raises PF but cuts trade count and net; re-entry blows up.

### 2b. Real-tick verification — M5, **Mar 20–Jul 24 2026**, Model = every real tick

> Only ~4 months of XAUUSD tick data are available on MetaQuotes-Demo (real ticks
> begin 2026.03.20), so this window is shorter than the OHLC sweep.

| Config | Net £ | PF | Trades | Won % | Max DD |
|--------|-------|------|--------|-------|--------|
| **B (bars 7)** | **+554** | **1.14** | **117** | **52.1%** | **5.8%** |
| C (bars 14) | +187 | 1.06 | 90 | 51.1% | 5.8% |

**Reality check:** the OHLC model badly *overstated* the edge (PF 1.75–2.07 → real
1.06–1.14). This is normal — OHLC modeling misjudges where stops/TPs fill. **B is the
real-tick winner** and is now the EA's default config.

---

## 3. Honest assessment

- The edge is **real but thin**: PF ~1.14, win rate ~52% at R:R 1.8, ~+5.5% over 4
  months with a ~5.8% max drawdown.
- It will **not** get rich quick, but it is **structurally safe** — unlike the grid,
  no single trend can blow the account. Every trade is stopped.
- The real-tick sample (~117 trades / 4 months) is **modest**. Treat these numbers as
  encouraging, not proven. Forward-test on demo before risking real money.

---

## 4. Chosen default config (config B — baked into the EA inputs)

| Input | Value |
|-------|-------|
| InpRiskMoney | 10.0 (£ risked per trade) |
| InpRewardRatio | 1.8 |
| InpStopAtrMult | 1.5 |
| InpBreakoutBars | **7** |
| InpBufferPoints | **10** |
| InpUseEmaFilter | **false** |
| InpAtrMinPips | 4.0 |
| InpBeTriggerR / InpBeLockPips | 1.0 / 1.0 |
| InpTrailAtrMult | 2.0 |
| InpOneTradePerBar | **true** (keep!) |
| InpDailyLossStop | 60.0 |
| InpAvoidRollover / InpRolloverHour | true / 23 |
| InpMagic | 77012024 |

Timeframe: **M5**. Symbol tested: **XAUUSD**.

---

## 5. How to run

### Live / demo (recommended next step: forward-test on demo)
1. Attach `MomentumScalper` to an **XAUUSD M5** chart.
2. Allow algo trading. The defaults are the tuned config B — no changes needed.
3. Watch the status panel: State, ATR, trend, day P/L, open-position R multiple,
   wins/losses.

### Headless back-test (reproduce these results)
- Config files live in `src/MomentumScalper/`:
  - `mscalp_backtest.ini` — single run template
  - `run_sweep.ps1` — the A–G parameter sweep driver
  - `run_realtick.ps1` — real-tick verification of the top configs
- Run a sweep:
  ```powershell
  powershell -ExecutionPolicy Bypass -File "src\MomentumScalper\run_sweep.ps1"
  ```
- Reports are written to the terminal data folder as `MScalp_*.htm`.
- Model codes in the `.ini`: `Model=1` = 1-min OHLC (fast), `Model=4` = real ticks (accurate).

### Deploy / compile target (Vantage terminal)
- Source: `src/MomentumScalper/MomentumScalper.mq5`
- Deployed to: `%APPDATA%\MetaQuotes\Terminal\92518C9899A1ED3884F29F1749EEC361\MQL5\Experts\MomentumScalper\`
- Compile: `metaeditor64.exe /compile:"...\MomentumScalper.mq5" /log`
  (read the `.log` — it's UTF-16 — for `Result: N errors`).

---

## 6. Ideas to improve the edge (future work)

- Test on more symbols/longer real-tick history (a proper broker feed, not the demo).
- Try a small **partial take-profit** (bank half at 1R, trail the rest).
- Add a higher-timeframe trend bias instead of the same-TF EMA filter.
- Walk-forward optimization rather than a single in-sample sweep, to guard against
  curve-fitting the ~117-trade sample.
