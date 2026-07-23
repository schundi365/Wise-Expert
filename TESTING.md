# WiseTrader — Automated Testing & Decision Guide

How to run regression campaigns with `Console\autotest.py` and, more importantly,
how to decide what the numbers mean. Written for WiseTrader EA v2.3+.

---

## 1. How it works (30-second version)

`autotest.py` launches its own headless MetaTrader (`terminal64.exe /config`),
runs the Strategy Tester once per `.set` config in `Tester Sets\`, and parses each
HTML report into one comparison file: `Tester Sets\regression_results.csv`.

Price data comes from the terminal's local history cache
(`Terminal\<hash>\bases\<broker-server>\`) — the same data your GUI tests use.
Missing history is downloaded automatically on first use (slow once, cached after).

**"Close MT5 first" means**: no *second* terminal may hold the data folder.
The script's own terminal instance is the one doing the work.

---

$env:WT_FROM="2025.07.01"; $env:WT_TO="2025.12.31"; python autotest.py --model 4 A2_tuned

:: 1. Out-of-sample (after the current run finishes)
python autotest.py --model 4 --from 2025.07.01 --to 2025.12.31 A2_tuned

:: 3. Cross-symbol sanity
python autotest.py --model 4 --symbol EURUSD A2_tuned
python autotest.py --model 4 --symbol XAGUSD A2_tuned



## 2. Local-folder workflow (no MT5 data folder needed)

You work ONLY in the project folder (`Wise Trader\MQL5\Experts\WiseTrader`).
On every campaign, `autotest.py` automatically:

1. **Links** the project folder into MT5 via a directory junction
   (`<data>\MQL5\Experts\WiseTrader` → project folder). No copies exist;
   an edit in the project folder IS what MT5 compiles and runs. If an old
   copied folder is found in the data folder it is renamed to
   `WiseTrader_backup_<timestamp>` first.
2. **Compiles** through the junction with `metaeditor64.exe /compile` and
   aborts the campaign on compile errors (`--skip-compile` to bypass).
3. **Collects evidence locally**: reports and `regression_results.csv` were
   already written to `Tester Sets\`; tagged journal CSVs are now also copied
   from MT5's Common\Files into `Tester Sets\journals\` after each run.

Remaining prerequisites per campaign:

- **Warm the data cache** (only when symbol/range/model is new): open MT5
  normally, run one short GUI tester pass with that symbol/range/model, close MT5.
- **Close MetaTrader completely** (system tray included) before running.

---

## 3. Running campaigns

```bat
cd "C:\Users\srika\Labs\AgenticAI\Trading library\Wise Trader\Console"

:: everything in Tester Sets\
python autotest.py :: a selected comparison (e.g. the exit-management D-series)

python autotest.py --model 0 A1_full_v20 C2_m1_close   :: tick-model runs



python autotest.py A1_full_v20 D1_early_lock D2_soft_lock D3_be_only

:: fast sweep (default) vs final validation
python autotest.py --model 1        :: M1 OHLC - minutes per run
python autotest.py --model 4        :: real ticks - slow, decision-grade
```

Overrides via environment variables (set before running, empty to clear):

| Variable | Default | Use |
|---|---|---|
| `WT_SYMBOL` | XAUUSD | `set WT_SYMBOL=XAGUSD` for silver campaigns |
| `WT_FROM` / `WT_TO` | 2026.01.01 / 2026.07.08 | test window |
| `WT_DEPOSIT` | 10000 | match intended account size (affects min-lot vetoes!) |
| `WT_TERMINAL` | C:\Program Files\MetaTrader 5\terminal64.exe | nonstandard install |
| `WT_MT5_DATA` | auto-detected | explicit data folder |

## 4. Outputs — where evidence lands

| Artifact | Location | Use |
|---|---|---|
| Comparison grid | `Tester Sets\regression_results.csv` | the decision table |
| Full MT5 report | `Tester Sets\report_<config>.htm` | equity curve, per-trade list |
| Tagged journal | `Common\Files\WiseTrader_<sym>_<magic>_<tag>.csv` | per-decision forensics: every setup, veto reason, management action |

Each run is stamped: journal filename carries the test-case tag (v2.3), and the
first line logs EA version + test case. A result you can't trace to a version
and config is not evidence.

---

## 5. Making the decision

### 5.1 The primary metric: expectancy

Rank configs by **`expectancy`** (Expected Payoff = net profit / trades).
Not net profit (rewards over-trading), not win rate (a 90% win rate loses money
if the 10% are big), not Sharpe in the tester (assumes zero risk-free rate and
is distorted by low trade counts).

### 5.2 Gates a winner must ALSO pass

A config only "wins" if, versus the reference config (A1):

- **Expectancy higher** — the point of the exercise.
- **Profit factor ≥ 1.15** — below that, spread/slippage variance can flip the sign.
- **Trades ≥ 50** in the window — below ~50 trades, differences are mostly luck.
  Below 30, ignore the campaign entirely and lengthen the date range.
- **Equity DD not worse than A1 by >25%** — expectancy bought with deeper
  drawdowns is a different (worse) strategy, not a better one.
- **Win rate × payoff sanity**: `wr × avgWin > (1−wr) × |avgLoss|` with margin.
  If a change raises win rate but collapses avgWin (the v2.2 lock problem —
  avgWin $31 vs avgLoss $62), it's scratching winners, not adding edge.

### 5.3 The two-step confirmation

1. **Sweep** on `--model 1` to shortlist (fast, slightly optimistic fills).
2. **Confirm the shortlist** (winner + A1 reference) on `--model 4` real ticks.
   Only model-4 numbers justify changing defaults. If the model-1 winner
   evaporates on model 4, it was a fill-model artifact — common for stop-order
   and tight-retest configs.

### 5.4 Interpreting the classic patterns

| Pattern in results | Meaning | Action |
|---|---|---|
| High wr, tiny avgWin, PF ≈ 1 | exits scratch winners | loosen locks/partials, better targets |
| Low wr (<40%), avgWin ≫ avgLoss, PF > 1.2 | healthy asymmetric system | fine — judge by expectancy only |
| One config great ONLY in one month | regime luck | check per-month P&L in the journal before trusting |
| B-series config beats A1 | that feature HURTS | disable it — deleting a feature is a win |
| Config trades 3× more than A1 | a gate broke | check veto counts in the tagged journal |
| `size < broker min` vetoes pile up | deposit too small for the symbol's stops | raise `WT_DEPOSIT` to intended size or drop the symbol |

### 5.5 After the decision

1. Update the chosen values as EA input defaults (one behavioral change per version).
2. Bump `#property version` + `CHANGELOG.md` entry with the evidence
   (config, window, model, expectancy before/after).
3. Keep the losing configs' reports — they document why the road not taken wasn't.
4. Re-run the full B-series occasionally: a feature that helped at v1.8 can hurt at v2.4.

---

## 6. Config catalog (Tester Sets\)

| Series | Question it answers |
|---|---|
| `A0` / `A1` | baseline (v1.6-like) / full current feature set — the references |
| `B1–B7` | ablation: each disables ONE feature; measures that feature's contribution vs A1 |
| `C1–C3` | entry mechanics: retest limits / M1-close breaks / stop orders |
| `D1–D4` | exit management: early lock / soft lock / breakeven-only / Friday flatten |
| `E1` | superseded — silver bin fix belongs on `S*`, not `E*` (silver ≠ EUR) |
| `E2`, `E3–E8` | EURUSD: `E2` = corrected profile_bin (0.0002) baseline; `E3–E6` re-test the A2_tuned toggles (ADX gate/vol-scaling/retest-limit/Friday-flatten) on EURUSD; `E7–E8` sweep alternate session windows |
| `S0–S4` | XAGUSD: `S0` = A2_tuned toggles baseline (per-symbol override is a no-op for silver); `S1–S4` re-test the same four toggles |
| `G0–G6` | GBPUSD (untested before v2.43): `G0` = baseline with the per-symbol override on; `G0_raw_bin` = same but override OFF, to prove the bin fix matters here too; `G1–G4` re-test the four toggles; `G5–G6` sweep alternate session windows |

**v2.43 per-symbol overrides**: `InpProfileBin` is the one distance input in the
whole EA that's an absolute price-unit constant instead of ATR-relative, so a
value tuned for XAUUSD's price scale is wrong on other symbols by construction
(confirmed on EURUSD: PF 0.85 → 1.12 just from fixing the bin). `src/SymbolProfile.mqh`
now applies known-good overrides per symbol automatically in `OnInit` — no more
manually setting `InpProfileBin` per `.set` file. `InpUseSymbolOverrides=false`
turns this off for control runs. Every init logs which override (if any) fired.

Naming convention for new configs: `<series letter><n>_<short_description>.set`,
and always include `InpTestTag=<filename stem>` (v2.3 does this for all shipped sets).

## 7. Troubleshooting

| Symptom | Fix |
|---|---|
| "terminal64.exe not found" | `set WT_TERMINAL=<path to terminal64.exe>` |
| "no report produced" | MT5 was still running — close it (check system tray) |
| Run finishes in seconds, 0 trades | history cache empty for that symbol/range — warm it via one GUI tester run |
| All configs identical results | EA not recompiled, or `.set` not applied — check `test_case=` in the journal init line |
| "could not create junction" | a real (non-junction) `WiseTrader` folder is locked in the data folder — close MetaEditor and retry, or delete/rename it manually |
| compile FAILED | open the reported `.log` (or compile in MetaEditor for the full error list); fix, rerun |
| Results differ from GUI run | different model, deposit, or date range — compare the ini values printed at campaign start |
| Wildly different runtimes | normal: model 4 is 10–50× slower than model 1 |

---

*Golden rule: one behavioral change per version, judged by expectancy on ≥50
trades, confirmed on real ticks, recorded in the changelog. Anything else is
optimizer archaeology.*
