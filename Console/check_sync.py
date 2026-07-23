"""Diagnose WiseTrader source divergence between the project folder and
every MT5 data folder copy (junctions, real folders, backups).

Run:  python check_sync.py
Then paste the output back to Claude for the merge plan.
"""
import os
import re
import stat as statmod
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
EA_SRC = PROJECT / "src" / "WiseTrader"
if not EA_SRC.exists():
    EA_SRC = PROJECT / "MQL5" / "Experts" / "WiseTrader"


def is_junction(p: Path) -> bool:
    try:
        return bool(os.lstat(p).st_file_attributes & statmod.FILE_ATTRIBUTE_REPARSE_POINT)
    except (OSError, AttributeError):
        return False


def version_of(folder: Path) -> str:
    f = folder / "WiseTrader.mq5"
    if not f.exists():
        return "-"
    txt = f.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r'#property\s+version\s+"([\d.]+)"', txt)
    return m.group(1) if m else "?"


def newest(folder: Path):
    files = [p for p in folder.rglob("*") if p.is_file() and p.suffix in (".mq5", ".mqh")]
    if not files:
        return None, "-"
    p = max(files, key=lambda x: x.stat().st_mtime)
    import datetime
    return p, datetime.datetime.fromtimestamp(p.stat().st_mtime).strftime("%Y-%m-%d %H:%M")


def describe(label: str, folder: Path):
    print(f"\n== {label}")
    print(f"   path:     {folder}")
    if not folder.exists():
        print("   (missing)")
        return
    kind = "JUNCTION" if is_junction(folder) else "real folder"
    tgt = ""
    if kind == "JUNCTION":
        try:
            tgt = f" -> {folder.resolve()}"
        except OSError:
            tgt = " -> (BROKEN target)"
    print(f"   type:     {kind}{tgt}")
    print(f"   version:  {version_of(folder)}")
    p, ts = newest(folder)
    print(f"   newest:   {p.name if p else '-'} @ {ts}")
    mq5 = folder / "WiseTrader.mq5"
    if mq5.exists():
        print(f"   mq5 size: {mq5.stat().st_size}")
    src = folder / "src"
    if src.exists():
        print(f"   modules:  {sorted(f.name for f in src.glob('*.mqh'))}")


print("PROJECT (single source of truth per workflow):")
describe("project", EA_SRC)

base = Path(os.environ.get("APPDATA", "")) / "MetaQuotes" / "Terminal"
for d in sorted(base.iterdir()) if base.exists() else []:
    exp = d / "MQL5" / "Experts"
    if not exp.exists():
        continue
    origin = ""
    o = d / "origin.txt"
    if o.exists():
        for enc in ("utf-16", "utf-8"):
            try:
                origin = o.read_text(encoding=enc).strip()
                break
            except UnicodeError:
                continue
    print(f"\n########## data folder {d.name[:8]}...  (install: {origin})")
    for w in sorted(exp.glob("WiseTrader*")):
        if w.is_dir():
            describe(w.name, w)

print("\nInterpretation guide:")
print(" - a REAL 'WiseTrader' folder in a data dir = diverged copy (should be a junction)")
print(" - 'WiseTrader_backup_*' folders = pre-junction copies autotest set aside")
print(" - highest version + newest timestamps show where the latest edits live")
