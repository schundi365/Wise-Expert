"""
WiseTrader WFE - Walk-Forward Efficiency scoring (F51).

Reimplements the scoring math (not the MQL5/CCanvas UI) from:
  "Implementing Walk-Forward Efficiency Ratio Scoring in MQL5 to Detect
  Over-Optimized Strategies" - MQL5 Articles, 2026-07-09.

WFE = SR_OOS / SR_IS, per window, with two guards:
  - SR_IS <= 0            -> WFE = 0.0 (unconditional failure; also blocks
                              the double-negative false positive where both
                              Sharpes are negative and naive division would
                              read as a positive score)
  - 0 < SR_IS < min_is_sr -> WFE = 0.0 (near-zero denominator guard; too
                              small a sample to be a trustworthy divisor)
  - otherwise             -> WFE = SR_OOS / SR_IS

Pass threshold: WFE >= 0.5 ("a window retaining at least half its in-sample
efficiency is treated as the minimum bar for robustness" - source article).

Unlike the source article's rolling N-window walk-forward setup, WiseTrader's
own campaigns use exactly ONE in-sample (tuning) window and ONE out-of-sample
(untouched) window per config, run as two separate Strategy Tester backtests.
So this tool treats each PAST CAMPAIGN CONFIG as one "window" and reuses the
Sharpe ratio MT5's own tester report already computes (already sitting in
results/regression_history.csv) rather than re-deriving Sharpe from a
per-bar equity series - that would require a companion EA/journal change the
Feature Log entry explicitly said wasn't needed for a first real test.

IMPORTANT: this tool answers "did this edge generalize, or was it curve-fit
to its tuning window" - it does NOT answer "is this better than our current
baseline." A config can score a clean WFE pass while still being weaker than
what's already live (see W1_volregime_on below: WFE says it generalized
fine, but its OOS numbers were only at parity with A2_tuned's own OOS run -
two different, both necessary, questions).

Usage:
  python wfe_score.py                          # run the built-in retroactive
                                                 # test (known campaign pairs)
  python wfe_score.py --is-sharpe 4.8 --oos-sharpe 5.65
  python wfe_score.py --config A2_tuned --symbol XAUUSD \
      --is-period 2026.01.01-2026.07.08 --oos-period 2025.07.01-2025.12.31
"""
import argparse
import csv
from pathlib import Path

MIN_IS_SHARPE = 0.25   # near-zero denominator floor, per source article
PASS_THRESHOLD = 0.5   # "retains at least half its in-sample efficiency"

ROOT = Path(__file__).resolve().parent.parent
HISTORY_CSV = ROOT / "results" / "regression_history.csv"

# Known IS/OOS role per config, from project memory (wise-trader-signal-tuning.md).
# Not inferable from the CSV alone - direction FLIPS per campaign (E9's tuning
# window was 2025H2, everyone else's was the 2026 primary window), so this is
# hand-curated, not auto-detected. Extend this table as new campaigns land.
KNOWN_PAIRS = [
    # (label, config, symbol, is_period, oos_period, model)
    ("A2_tuned (XAUUSD, the validated deploy baseline)",
     "A2_tuned", "XAUUSD", "2026.01.01-2026.07.08", "2025.07.01-2025.12.31", "4"),
    ("E9_eur_tuned (EURUSD, KNOWN overfit collapse - IS window was 2025H2)",
     "E9_eur_tuned", "EURUSD", "2025.07.01-2025.12.31", "2026.01.01-2026.07.08", "4"),
    ("S5_silver_tuned (XAGUSD, KNOWN overfit collapse)",
     "S5_silver_tuned", "XAGUSD", "2026.01.01-2026.07.08", "2025.07.01-2025.12.31", "4"),
    ("W1_volregime_on (XAUUSD, F55 - 'parity OOS' verdict from this session)",
     "W1_volregime_on", "XAUUSD", "2026.01.01-2026.07.08", "2025.07.01-2025.12.31", "4"),
]


def compute_wfe(sr_is: float, sr_oos: float, min_is_sharpe: float = MIN_IS_SHARPE) -> float:
    """Direct port of ComputeWFE() from the source article. Three branches,
    in order: non-positive IS guard, near-zero IS guard, then the ratio."""
    if sr_is <= 0.0:
        return 0.0
    if sr_is < min_is_sharpe:
        return 0.0
    return sr_oos / sr_is


def status(wfe: float) -> str:
    return "PASS" if wfe >= PASS_THRESHOLD else "FAIL"


def read_sharpe(config: str, symbol: str, period: str, model: str = None) -> float:
    """Pull the Sharpe MT5's tester report already computed for this
    config+symbol+period out of regression_history.csv. Prefers the given
    model (4 = real ticks, most trustworthy); falls back to any model if
    that exact combination isn't there. Returns None if not found."""
    if not HISTORY_CSV.exists():
        raise SystemExit(f"not found: {HISTORY_CSV} (run from a machine with the project folder)")
    best = None
    with open(HISTORY_CSV, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row.get("config") != config or row.get("symbol") != symbol or row.get("period") != period:
                continue
            if not row.get("sharpe"):
                continue
            if model is not None and row.get("model") == model:
                return float(row["sharpe"])
            best = float(row["sharpe"])  # keep the last match as a fallback
    return best


def print_row(label: str, sr_is: float, sr_oos: float) -> float:
    wfe = compute_wfe(sr_is, sr_oos)
    print(f"{label}\n"
          f"  IS Sharpe={sr_is:7.2f}   OOS Sharpe={sr_oos:7.2f}   "
          f"WFE={wfe:7.4f}   {status(wfe)}")
    return wfe


def run_known_pairs():
    print(f"WFE retroactive test - {len(KNOWN_PAIRS)} known campaign pairs "
          f"(pass threshold {PASS_THRESHOLD}, min IS Sharpe {MIN_IS_SHARPE})\n")
    scores = []
    for label, config, symbol, is_period, oos_period, model in KNOWN_PAIRS:
        sr_is = read_sharpe(config, symbol, is_period, model)
        sr_oos = read_sharpe(config, symbol, oos_period, model)
        if sr_is is None or sr_oos is None:
            print(f"{label}\n  SKIPPED - missing data (is={sr_is}, oos={sr_oos})\n")
            continue
        wfe = print_row(label, sr_is, sr_oos)
        scores.append(wfe)
        print()
    if scores:
        mean_wfe = sum(scores) / len(scores)
        passes = sum(1 for w in scores if w >= PASS_THRESHOLD)
        print(f"--- summary across {len(scores)} scored pairs ---")
        print(f"mean WFE: {mean_wfe:.4f}   pass rate: {passes}/{len(scores)} "
              f"({100*passes/len(scores):.0f}%)   min: {min(scores):.4f}   max: {max(scores):.4f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--is-sharpe", type=float, help="in-sample Sharpe (skip CSV lookup)")
    ap.add_argument("--oos-sharpe", type=float, help="out-of-sample Sharpe (skip CSV lookup)")
    ap.add_argument("--config", help="config name to look up in regression_history.csv")
    ap.add_argument("--symbol", help="symbol to look up")
    ap.add_argument("--is-period", help="in-sample period string, e.g. 2026.01.01-2026.07.08")
    ap.add_argument("--oos-period", help="out-of-sample period string")
    ap.add_argument("--model", default="4", help="preferred model to pull Sharpe from (default 4)")
    args = ap.parse_args()

    if args.is_sharpe is not None and args.oos_sharpe is not None:
        print_row(f"ad-hoc: IS Sharpe={args.is_sharpe}, OOS Sharpe={args.oos_sharpe}",
                   args.is_sharpe, args.oos_sharpe)
        return

    if args.config and args.symbol and args.is_period and args.oos_period:
        sr_is = read_sharpe(args.config, args.symbol, args.is_period, args.model)
        sr_oos = read_sharpe(args.config, args.symbol, args.oos_period, args.model)
        if sr_is is None or sr_oos is None:
            raise SystemExit(f"could not find Sharpe for {args.config}/{args.symbol} "
                              f"at is={args.is_period!r} or oos={args.oos_period!r} "
                              f"in {HISTORY_CSV} - check the period strings match exactly")
        print_row(f"{args.config} ({args.symbol})", sr_is, sr_oos)
        return

    run_known_pairs()


if __name__ == "__main__":
    main()
