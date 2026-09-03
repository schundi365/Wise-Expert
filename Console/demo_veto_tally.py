"""
WiseTrader demo veto tally.

Reads the live DEMO_LIVE journal and buckets every VETO line into a
category, plus a summary of trades taken. Re-reads the whole journal
from demo start each time rather than tracking incremental state - the
file stays small for the length of a 4-week demo, and re-deriving from
scratch avoids any risk of double-counting or drift.

Usage:
  python demo_veto_tally.py [path-to-journal-csv]

Default journal path assumes the standard Common\\Files location and the
DEMO_LIVE tag set up 2026-08-06 (see wise-trader-demo-tracking memory).
"""
import re
import sys
from collections import Counter
from pathlib import Path

DEFAULT_JOURNAL = (
    Path.home() / "AppData" / "Roaming" / "MetaQuotes" / "Terminal" / "Common" / "Files"
    / "WiseTrader_XAUUSD_20260707_DEMO_LIVE.csv"
)

# Order matters: first matching pattern wins.
CATEGORY_PATTERNS = [
    ("News window", re.compile(r"authorization denied: news window")),
    ("Outlier bar masked", re.compile(r"outlier bar masked")),
    ("RelVol (volume) veto", re.compile(r"signal rejected: volume: relVol")),
    ("Score threshold", re.compile(r"signal rejected: score")),
    ("ADX / chop regime", re.compile(r"regime: chop ADX")),
    ("RR fail", re.compile(r"RRfail")),
    ("Break setup validation fail", re.compile(r"break setup failed validation")),
    ("Friday/news flatten", re.compile(r"FLATTEN ALL")),
    ("Other veto", re.compile(r"VETO")),  # catch-all, checked last
]


def categorize(message: str) -> str:
    for label, pattern in CATEGORY_PATTERNS:
        if pattern.search(message):
            return label
    return "Uncategorized"


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_JOURNAL
    if not path.exists():
        sys.exit(f"journal not found: {path}\n"
                  f"(pass the path explicitly, or check the demo's InpTestTag matches)")

    veto_counter = Counter()
    veto_examples = {}
    trades = []
    init_lines = []

    with open(path, encoding="utf-8") as f:
        next(f, None)  # header
        for line in f:
            parts = line.rstrip("\n").split(";", 2)
            if len(parts) < 3:
                continue
            time, tag, message = parts
            if tag == "RECOVER" and "init:" in message:
                init_lines.append((time, message))
            elif tag == "VETO":
                cat = categorize(message)
                veto_counter[cat] += 1
                veto_examples.setdefault(cat, (time, message))
            elif tag == "RISK" and "deal closed" in message:
                m = re.search(r"pnl=(-?[\d.]+)", message)
                if m:
                    trades.append((time, float(m.group(1))))

    print(f"journal: {path}")
    print(f"init/restart events: {len(init_lines)}")
    if init_lines:
        print(f"  first: {init_lines[0][0]}   last: {init_lines[-1][0]}")
    print()

    total_vetoes = sum(veto_counter.values())
    print(f"--- veto breakdown ({total_vetoes} total) ---")
    for cat, count in veto_counter.most_common():
        pct = 100 * count / total_vetoes if total_vetoes else 0
        ex_time, ex_msg = veto_examples[cat]
        print(f"  {cat:28s} {count:4d}  ({pct:4.1f}%)   e.g. [{ex_time}] {ex_msg[:80]}")

    print()
    print(f"--- trades closed ({len(trades)}) ---")
    if trades:
        net = sum(pnl for _, pnl in trades)
        wins = [pnl for _, pnl in trades if pnl > 0]
        losses = [pnl for _, pnl in trades if pnl <= 0]
        print(f"  net P&L: {net:.2f}   win rate: {100*len(wins)/len(trades):.1f}% "
              f"({len(wins)}/{len(trades)})   expectancy: {net/len(trades):.2f}/trade")
        for t, pnl in trades:
            print(f"    [{t}] pnl={pnl:+.2f}")
    else:
        print("  none yet")

    print()
    print(f"--- gate check ---")
    print(f"  trades so far: {len(trades)} / 20 minimum")
    if trades:
        exp = sum(pnl for _, pnl in trades) / len(trades)
        print(f"  cumulative expectancy: {exp:.2f} (need >= 3.75 to pass, at >=20 trades and 4 weeks)")


if __name__ == "__main__":
    main()
