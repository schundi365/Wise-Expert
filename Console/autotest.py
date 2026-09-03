"""
WiseTrader AutoTest - unattended Strategy Tester regression runner.

Local-folder workflow: the project folder is the single source of truth.
On every campaign this script (1) junctions <MT5 data>\\MQL5\\Experts\\WiseTrader
to the project folder, (2) compiles via metaeditor64, (3) runs terminal64.exe
headlessly (/config) once per .set config, (4) parses each report into
Tester Sets/regression_results.csv and (5) copies tagged journals back into
Tester Sets/journals/.

Usage:
  python autotest.py                            # run all Tester Sets/*.set
  python autotest.py A1_full_v20 B3_no_retest   # run selected configs
  python autotest.py --model 1                  # 1-minute OHLC (fast sweep, default)
  python autotest.py --model 4                  # real ticks (slow, final validation)
  python autotest.py --skip-compile             # skip the metaeditor64 build step

Env overrides:
  WT_TERMINAL   path to terminal64.exe
  WT_MT5_DATA   MT5 data folder (else matched via origin.txt)
  WT_SYMBOL / WT_FROM / WT_TO / WT_DEPOSIT

IMPORTANT: close MetaTrader 5 before running - the terminal cannot be
driven by /config while another instance uses the same data folder.
"""
import argparse
import csv
import json
import os
import re
import shutil
import stat as statmod
import subprocess
import sys
import time
from html.parser import HTMLParser
from pathlib import Path

# ----------------------------------------------------------------- config ---
TERMINAL = os.environ.get("WT_TERMINAL", r"C:\Program Files\MetaTrader 5\terminal64.exe")
SYMBOL   = os.environ.get("WT_SYMBOL", "XAUUSD")
PERIOD   = "M15"
FROMDATE = os.environ.get("WT_FROM", "2026.01.01")
TODATE   = os.environ.get("WT_TO", "2026.07.08")
DEPOSIT  = os.environ.get("WT_DEPOSIT", "10000")
EXPERT   = r"WiseTrader\WiseTrader"          # relative to MQL5\Experts

def _find_root() -> Path:
    """Repo root, tolerant of BOTH layouts: new (tools/console) and
    legacy (Console). Walk up until a folder with configs is found."""
    for p in Path(__file__).resolve().parents:
        if (p / "tests" / "configs").exists() or (p / "Tester Sets").exists():
            return p
    sys.exit("cannot locate repo root: no 'tests\\configs' or 'Tester Sets' "
             "folder above " + str(Path(__file__).resolve()))

ROOT = _find_root()
if (ROOT / "tests" / "configs").exists():      # new CI/CD layout
    SETS_DIR = ROOT / "tests" / "configs"
    RESULTS  = ROOT / "results"
    EA_SRC   = ROOT / "src" / "WiseTrader"
else:                                          # legacy layout (pre setup_git.bat)
    SETS_DIR = ROOT / "Tester Sets"
    RESULTS  = ROOT / "Tester Sets"
    EA_SRC   = ROOT / "MQL5" / "Experts" / "WiseTrader"
OUT_CSV  = RESULTS / "regression_results.csv"
STATUS_JSON = RESULTS / "campaign_status.json"    # read by dashboard.py
COMMON_FILES = Path(os.environ.get("APPDATA", "")) / "MetaQuotes" / "Terminal" / "Common" / "Files"


# --------------------------------------------- local-folder workflow --------
def is_junction(p: Path) -> bool:
    try:
        return bool(os.lstat(p).st_file_attributes & statmod.FILE_ATTRIBUTE_REPARSE_POINT)
    except (OSError, AttributeError):
        return False


def ensure_junction(data_dir: Path) -> None:
    """MT5 sees Experts\\WiseTrader as a junction into the PROJECT folder.
    No file copies: edits in the project folder are what MT5 compiles/runs."""
    link = data_dir / "MQL5" / "Experts" / "WiseTrader"
    if is_junction(link):
        try:
            if link.resolve() == EA_SRC.resolve():
                return
        except OSError:
            pass
        #--- stale junction (repo was restructured): drop and relink
        subprocess.run(["cmd", "/c", "rmdir", str(link)], capture_output=True)
    if link.exists():
        backup = link.with_name(f"WiseTrader_backup_{time.strftime('%Y%m%d_%H%M%S')}")
        link.rename(backup)
        print(f"note: existing copy in the data folder moved to {backup.name}; "
              f"the project folder is now the single source")
    r = subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(EA_SRC)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"could not create junction: {r.stderr.strip() or r.stdout.strip()}")
    print(f"junction: {link} -> {EA_SRC}")


def compile_ea(data_dir: Path) -> None:
    """Compile through the junction so <includes> resolve against the terminal's
    MQL5 folder. Aborts the campaign on compile errors."""
    me = Path(TERMINAL).with_name("metaeditor64.exe")
    if not me.exists():
        sys.exit("metaeditor64.exe not found next to terminal64.exe - "
                 "compile manually in MetaEditor or fix WT_TERMINAL")
    src = data_dir / "MQL5" / "Experts" / "WiseTrader" / "WiseTrader.mq5"
    logf = src.with_suffix(".log")
    if logf.exists():
        logf.unlink()
    subprocess.run([str(me), f"/compile:{src}", "/log"], check=False)
    txt = ""
    if logf.exists():
        for enc in ("utf-16", "utf-8"):
            try:
                txt = logf.read_text(encoding=enc)
                break
            except UnicodeError:
                continue
    m = re.search(r"(\d+)\s+errors?,\s+(\d+)\s+warnings?", txt)
    if m and int(m.group(1)) > 0:
        sys.exit(f"compile FAILED: {m.group(0)} - see {logf}")
    print(f"compiled: {m.group(0) if m else 'OK (log not parsed)'}")


def collect_journals(name: str) -> None:
    """Copy the run's tagged journal CSVs from MT5 Common\\Files into the
    project folder so all evidence lives locally."""
    dest = RESULTS / "journals"
    dest.mkdir(parents=True, exist_ok=True)
    for p in COMMON_FILES.glob(f"WiseTrader_*_{name}.csv"):
        shutil.copy(p, dest / p.name)


def find_data_dir() -> Path:
    """The launched terminal uses the data folder tied to ITS install path
    (recorded in each Terminal\\<hash>\\origin.txt). Match on that - guessing
    by folder contents can pick a different hash than the terminal will use."""
    env = os.environ.get("WT_MT5_DATA")
    if env:
        return Path(env)
    base = Path(os.environ.get("APPDATA", "")) / "MetaQuotes" / "Terminal"
    dirs = [d for d in (base.iterdir() if base.exists() else []) if d.is_dir()]
    install = str(Path(TERMINAL).parent).lower().rstrip("\\")
    for d in dirs:
        o = d / "origin.txt"
        if not o.exists():
            continue
        txt = ""
        for enc in ("utf-16", "utf-8"):
            try:
                txt = o.read_text(encoding=enc).strip().lower().rstrip("\\")
                break
            except UnicodeError:
                continue
        if txt == install:
            return d
    #--- fallback heuristics (single-install machines)
    for d in dirs:
        if (d / "MQL5" / "Experts" / "WiseTrader").exists():
            return d
    for d in dirs:
        if (d / "MQL5" / "Experts").exists():
            return d
    sys.exit("MT5 data folder not found - set WT_MT5_DATA")


def tail_terminal_logs(data_dir: Path, lines: int = 12) -> None:
    """Print the tail of the newest terminal/tester logs - the actual reason
    a headless run aborted is always written there."""
    cands = list((data_dir / "logs").glob("*.log")) \
          + list((data_dir / "Tester").glob("**/logs/*.log")) \
          + list((data_dir / "Tester").glob("*.log"))
    if not cands:
        print("  (no terminal logs found under", data_dir, ")")
        return
    newest = max(cands, key=lambda p: p.stat().st_mtime)
    raw = newest.read_bytes()
    txt = ""
    for enc in ("utf-16", "utf-8", "cp1252"):
        try:
            txt = raw.decode(enc)
            break
        except UnicodeError:
            continue
    print(f"  --- tail of {newest} ---")
    for ln in [l for l in txt.splitlines() if l.strip()][-lines:]:
        print("  ", ln)


# ------------------------------------------------------------ report parse --
class _Text(HTMLParser):
    def __init__(self):
        super().__init__()
        self.chunks = []
    def handle_data(self, data):
        d = data.strip()
        if d:
            self.chunks.append(d)


def read_report(path: Path) -> dict:
    """Parse the tester .htm report: label/value pairs from the stats table."""
    raw = path.read_bytes()
    for enc in ("utf-16", "utf-8", "cp1252"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeError:
            continue
    p = _Text()
    p.feed(text)
    t = p.chunks
    want = {
        "Total Net Profit:": "net_profit",
        "Profit Factor:": "profit_factor",
        "Expected Payoff:": "expectancy",
        "Recovery Factor:": "recovery",
        "Sharpe Ratio:": "sharpe",
        "Balance Drawdown Maximal:": "max_dd",
        "Equity Drawdown Maximal:": "equity_dd",
        "Total Trades:": "trades",
        "Total Deals:": "deals",
        "Profit Trades (% of total):": "win_rate",
        "Average profit trade:": "avg_win",
        "Average loss trade:": "avg_loss",
    }
    out = {}
    for i, chunk in enumerate(t):
        key = want.get(chunk)
        if key and i + 1 < len(t) and key not in out:
            out[key] = t[i + 1]
    return out


def write_campaign(state: dict) -> None:
    """Progress snapshot for the Console dashboard's Campaign card. The
    dashboard polls this file; autotest never talks to Flask directly."""
    state["updated"] = time.strftime("%Y-%m-%d %H:%M:%S")
    try:
        STATUS_JSON.write_text(json.dumps(state, indent=1), encoding="utf-8")
    except OSError:
        pass          # a monitoring failure must never kill a campaign


# ------------------------------------------------------------------- runs ---
def run_one(name: str, data_dir: Path, model: int) -> dict:
    profiles = data_dir / "MQL5" / "Profiles" / "Tester"
    profiles.mkdir(parents=True, exist_ok=True)
    shutil.copy(SETS_DIR / f"{name}.set", profiles / f"{name}.set")

    #--- Report= is a NAME relative to the data folder: absolute paths with
    #--- spaces silently fail on some builds. Write locally, then move.
    window = f"{FROMDATE.replace('.','')}-{TODATE.replace('.','')}"
    report_stem = f"wt_report_{name}_{SYMBOL}_{window}"
    ini = data_dir / f"wt_autotest_{name}.ini"
    ini.write_text(
        "[Tester]\n"
        f"Expert={EXPERT}\n"
        f"ExpertParameters={name}.set\n"
        f"Symbol={SYMBOL}\n"
        f"Period={PERIOD}\n"
        f"Model={model}\n"
        "Optimization=0\n"
        f"FromDate={FROMDATE}\n"
        f"ToDate={TODATE}\n"
        "ForwardMode=0\n"
        + (f"Login={os.environ['WT_LOGIN']}\n" if os.environ.get("WT_LOGIN") else "")
        + f"Deposit={DEPOSIT}\n"
        "Currency=USD\n"
        "Leverage=1:100\n"
        "Visual=0\n"
        f"Report={report_stem}\n"
        "ReplaceReport=1\n"
        "ShutdownTerminal=1\n",
        encoding="utf-16",
    )
    t0 = time.time()
    print(f"[{name}] running...", flush=True)
    subprocess.run([TERMINAL, f"/config:{ini}"], check=False)
    #--- the terminal can spawn a LiveUpdate child that outlives it; launching
    #--- the next config while it lingers yields 'terminal process already
    #--- started' and a silent no-op run. Wait until every instance is gone.
    t_wait = time.time()
    while time.time() - t_wait < 90:
        try:
            chk = subprocess.run(["tasklist", "/FI", "IMAGENAME eq terminal64.exe"],
                                 capture_output=True, text=True)
        except FileNotFoundError:
            break
        if "terminal64.exe" not in chk.stdout:
            break
        time.sleep(2)
    else:
        print("  warning: terminal64.exe still alive after 90s - "
              "a platform update may be looping; run MT5 once as Administrator")
    # report lands in the DATA folder (terminal appends .htm/.html); move it home
    htm = None
    RESULTS.mkdir(parents=True, exist_ok=True)   # guard: never lose a report
    for ext in (".htm", ".html"):
        cand = data_dir / (report_stem + ext)
        if cand.exists():
            htm = RESULTS / f"report_{name}_{SYMBOL}_{window}{ext}"
            shutil.move(str(cand), htm)
            break
    row = {"config": name, "model": model, "runtime_s": round(time.time() - t0)}
    if htm is None:
        row["error"] = "no report - see terminal log tail above"
        print(f"[{name}] FAILED: no report. Terminal's own explanation:", flush=True)
        tail_terminal_logs(data_dir)
        if row["runtime_s"] < 10:
            print("  hint: the terminal exited immediately. Most common causes:\n"
                  "   1) pending platform update (log shows 'LiveUpdate') -> run\n"
                  "      MT5 once as Administrator, let it update, close it\n"
                  "   2) another terminal64.exe still running (Task Manager)",
                  flush=True)
        return row
    row.update(read_report(htm))
    collect_journals(name)
    print(f"[{name}] done in {row['runtime_s']}s  "
          f"net={row.get('net_profit','?')} pf={row.get('profit_factor','?')} "
          f"trades={row.get('trades','?')}", flush=True)
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("configs", nargs="*", help="config names (default: all .set files)")
    ap.add_argument("--model", type=int, default=1,
                    help="0 every tick | 1 M1 OHLC (fast, default) | 4 real ticks")
    ap.add_argument("--skip-compile", action="store_true",
                    help="skip the metaeditor64 compile step")
    #--- CLI overrides beat env vars: PowerShell's `set X=Y` does NOT create
    #--- environment variables (CMD syntax), which silently ran the wrong
    #--- window once. Flags work identically in every shell.
    ap.add_argument("--from", dest="from_date", metavar="YYYY.MM.DD",
                    help="test window start (overrides WT_FROM)")
    ap.add_argument("--to", dest="to_date", metavar="YYYY.MM.DD",
                    help="test window end (overrides WT_TO)")
    ap.add_argument("--symbol", help="tester symbol (overrides WT_SYMBOL)")
    ap.add_argument("--period", help="tester CHART period (M1/M5/M15/M30/H1/H4/D1/...). "
                    "Should match the InpTF being tested in the .set - a mismatch (e.g. "
                    "chart on M15 while InpTF=H1) can make the tester fail to build the "
                    "H1 history cache headlessly (default: M15)")
    args = ap.parse_args()

    global FROMDATE, TODATE, SYMBOL, PERIOD
    if args.from_date:
        FROMDATE = args.from_date
    if args.to_date:
        TODATE = args.to_date
    if args.symbol:
        SYMBOL = args.symbol
    if args.period:
        PERIOD = args.period

    #--- refuse to start while any terminal64.exe is running: a second
    #--- instance ignores /config and exits silently ("no report", 1s runs)
    try:
        chk = subprocess.run(["tasklist", "/FI", "IMAGENAME eq terminal64.exe"],
                             capture_output=True, text=True)
        if "terminal64.exe" in chk.stdout:
            sys.exit("terminal64.exe is RUNNING - close MetaTrader 5 completely "
                     "(check Task Manager) and re-run. A second instance ignores "
                     "/config and exits at once, producing 'no report' for every config.")
    except FileNotFoundError:
        pass                       # non-Windows (dev checks only)

    #--- layout sanity (root detection already handled both layouts)
    if not EA_SRC.exists():
        sys.exit(f"EA source not found at {EA_SRC} - repo half-restructured? "
                 "Finish setup_git.bat, or restore the folder, then re-run.")
    print(f"layout: {'CI/CD' if SETS_DIR.name == 'configs' else 'legacy'}  root: {ROOT}")
    if not Path(TERMINAL).exists():
        sys.exit(f"terminal64.exe not found at {TERMINAL} - set WT_TERMINAL")
    data_dir = find_data_dir()
    ensure_junction(data_dir)
    if not args.skip_compile:
        compile_ea(data_dir)
    RESULTS.mkdir(parents=True, exist_ok=True)
    names = args.configs or sorted(p.stem for p in SETS_DIR.glob("*.set"))
    print(f"data dir: {data_dir}\nconfigs: {', '.join(names)}\n"
          f"{SYMBOL} {PERIOD} {FROMDATE}-{TODATE} model={args.model}\n")

    state = {"symbol": SYMBOL, "period": f"{FROMDATE}-{TODATE}", "model": args.model,
             "configs": names, "current": "", "done": [], "finished": False,
             "started": time.strftime("%Y-%m-%d %H:%M:%S")}
    rows = []
    for n in names:
        state["current"] = n
        write_campaign(state)
        row = run_one(n, data_dir, args.model)
        rows.append(row)
        state["done"].append({k: row.get(k, "") for k in
                              ("config", "net_profit", "profit_factor",
                               "trades", "max_dd", "runtime_s", "error")})
        write_campaign(state)
    state["current"] = ""
    state["finished"] = True
    write_campaign(state)

    fields = ["config", "model", "trades", "net_profit", "profit_factor",
              "expectancy", "win_rate", "avg_win", "avg_loss", "max_dd",
              "equity_dd", "recovery", "sharpe", "deals", "runtime_s", "error"]
    with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)

    #--- permanent record: every campaign row appends to the history file
    #--- (regression_results.csv is overwritten per campaign; this is not)
    hist = RESULTS / "regression_history.csv"
    hfields = ["campaign", "symbol", "period"] + fields
    new_file = not hist.exists()
    with open(hist, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=hfields, extrasaction="ignore")
        if new_file:
            w.writeheader()
        for r in rows:
            w.writerow({"campaign": state["started"], "symbol": SYMBOL,
                        "period": f"{FROMDATE}-{TODATE}", **r})
    print(f"\nresults -> {OUT_CSV}\nhistory  -> {hist}")


if __name__ == "__main__":
    main()
