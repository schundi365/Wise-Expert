"""CI guardrails for Wise-Expert. Fails the build on:
   - malformed / incomplete .set regression configs
   - EA #property version not matching the newest CHANGELOG entry
   - EA source referencing includes that do not exist
Run locally too:  python .github/scripts/validate_repo.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
errors = []

# --- 1. .set configs: required keys present, one value per line -------------
REQUIRED = ["InpMagic", "InpRiskPerTrade", "InpMaxDailyLoss", "InpMaxTotalDD",
            "InpMinScore", "InpSessionStart", "InpSessionEnd"]
sets = sorted((ROOT / "tests" / "configs").glob("*.set"))
if not sets:
    errors.append("no .set configs found in tests/configs/")
for f in sets:
    txt = f.read_text(encoding="utf-8", errors="ignore")
    keys = {m.group(1) for m in re.finditer(r"^(\w+)=", txt, re.M)}
    missing = [k for k in REQUIRED if k not in keys]
    if missing:
        errors.append(f"{f.name}: missing keys {missing}")

# --- 2. EA version == newest CHANGELOG version -------------------------------
ea = ROOT / "src" / "WiseTrader" / "WiseTrader.mq5"
src = ea.read_text(encoding="utf-8", errors="ignore")
m_prop = re.search(r'#property\s+version\s+"([\d.]+)"', src)
m_log = re.search(r"## WiseTrader EA v([\d.]+)", (ROOT / "CHANGELOG.md")
                  .read_text(encoding="utf-8", errors="ignore"))
if not m_prop:
    errors.append("no #property version in WiseTrader.mq5")
elif not m_log:
    errors.append("no 'WiseTrader EA vX.Y' entry in CHANGELOG.md")
else:
    prop, log = float(m_prop.group(1)), float(m_log.group(1))
    if abs(prop - log) > 1e-9:
        errors.append(f"version mismatch: EA #property {prop} vs CHANGELOG {log} "
                      "(changelog discipline: bump both together)")

# --- 3. includes referenced by the EA exist ---------------------------------
for m in re.finditer(r'#include\s+"([^"]+)"', src):
    if not (ea.parent / m.group(1)).exists():
        errors.append(f"WiseTrader.mq5 includes missing file: {m.group(1)}")

if errors:
    print("VALIDATION FAILED:")
    for e in errors:
        print("  -", e)
    sys.exit(1)
print(f"validation OK: {len(sets)} configs, EA v{m_prop.group(1)}")
