"""
WiseTrader Console - Flask dashboard for the WiseTrader MQL5 EA.

Talks to the EA through the MT5 Common\\Files bridge:
  WiseTrader_<SYMBOL>_<MAGIC>.status.json  (EA -> console, 1s snapshots)
  WiseTrader_<SYMBOL>_<MAGIC>.csv          (EA -> console, journal)
  WiseTrader_<SYMBOL>_<MAGIC>.cmd          (console -> EA, one-line command)
  WiseTrader_<SYMBOL>_<MAGIC>.ack          (EA -> console, command result)

Account/positions/history come from the MetaTrader5 Python package when
available; everything else works even without it.

Run:  python dashboard.py           (then open http://127.0.0.1:5088)
"""
import json
import os
import time
from pathlib import Path

from flask import Flask, jsonify, request, Response

# ----------------------------------------------------------------- config ---
SYMBOL = os.environ.get("WT_SYMBOL", "XAUUSD")
MAGIC = int(os.environ.get("WT_MAGIC", "20260707"))
PORT = int(os.environ.get("WT_PORT", "5088"))
COMMON_FILES = os.environ.get(
    "WT_COMMON",
    os.path.join(os.environ.get("APPDATA", ""), "MetaQuotes", "Terminal", "Common", "Files"),
)

def _campaign_file():
    """campaign_status.json in either layout (results/ or Tester Sets/)."""
    for p in Path(__file__).resolve().parents:
        for sub in ("results", "Tester Sets"):
            if (p / sub).is_dir():
                return p / sub / "campaign_status.json"
    return Path("campaign_status.json")

CAMPAIGN_FILE = _campaign_file()

BASE = f"WiseTrader_{SYMBOL}_{MAGIC}"
STATUS_FILE = Path(COMMON_FILES) / f"{BASE}.status.json"
JOURNAL_FILE = Path(COMMON_FILES) / f"{BASE}.csv"
CMD_FILE = Path(COMMON_FILES) / f"{BASE}.cmd"
ACK_FILE = Path(COMMON_FILES) / f"{BASE}.ack"

LOCKS = {0: "none", 1: "DAILY LOSS", 2: "LOSS STREAK", 3: "TOTAL DD"}
STATES = {0: "NO_SETUP", 1: "FORMING", 2: "CONFIRMED", 3: "ACTIVE", 4: "EXPIRED"}
TRENDS = {1: "BULL", -1: "BEAR", 0: "-"}

# Optional MetaTrader5 package
try:
    import MetaTrader5 as mt5

    MT5_OK = mt5.initialize()
except Exception:
    mt5 = None
    MT5_OK = False

app = Flask(__name__)


# ------------------------------------------------------------------ helpers -
def read_status():
    try:
        raw = STATUS_FILE.read_text(encoding="utf-8", errors="ignore").strip()
        s = json.loads(raw)
        s["lock_txt"] = LOCKS.get(s.get("lock", 0), "?")
        s["state_txt"] = STATES.get(s.get("setup_state", 0), "?")
        s["trend_txt"] = TRENDS.get(s.get("trend", 0), "-")
        s["age_sec"] = max(0, time.time() - STATUS_FILE.stat().st_mtime)
        s["ea_alive"] = s["age_sec"] < 10
        return s
    except Exception as e:
        return {"error": f"no status file ({e.__class__.__name__}) - is the EA running?",
                "ea_alive": False}


def read_logs(tail=300, tag=""):
    try:
        lines = JOURNAL_FILE.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return []
    rows = []
    for ln in lines[1:]:
        parts = ln.split(";", 2)
        if len(parts) != 3:
            continue
        if tag and parts[1] != tag:
            continue
        rows.append({"time": parts[0], "tag": parts[1], "msg": parts[2]})
    return rows[-tail:]


def mt5_positions():
    if not MT5_OK:
        return []
    poss = mt5.positions_get(symbol=SYMBOL) or []
    out = []
    for p in poss:
        if p.magic != MAGIC:
            continue
        out.append({
            "ticket": p.ticket,
            "type": "BUY" if p.type == 0 else "SELL",
            "volume": p.volume,
            "open": p.price_open,
            "current": p.price_current,
            "sl": p.sl,
            "tp": p.tp,
            "profit": p.profit,
        })
    return out


def mt5_history(days=30):
    if not MT5_OK:
        return {"available": False}
    from datetime import datetime, timedelta

    deals = mt5.history_deals_get(datetime.now() - timedelta(days=days), datetime.now()) or []
    closed = [d for d in deals if d.magic == MAGIC and d.symbol == SYMBOL and d.entry == 1]
    wins = [d for d in closed if d.profit > 0]
    total = sum(d.profit + d.swap + d.commission for d in closed)
    return {
        "available": True,
        "trades": len(closed),
        "wins": len(wins),
        "win_rate": round(100 * len(wins) / len(closed), 1) if closed else 0.0,
        "net_profit": round(total, 2),
    }


# ---------------------------------------------------------------- endpoints -
@app.get("/api/status")
def api_status():
    s = read_status()
    if MT5_OK:
        acc = mt5.account_info()
        if acc:
            s["account"] = {"login": acc.login, "balance": acc.balance,
                            "equity": acc.equity, "profit": acc.profit}
    s["mt5_api"] = MT5_OK
    return jsonify(s)


@app.get("/api/logs")
def api_logs():
    return jsonify(read_logs(int(request.args.get("tail", 300)),
                             request.args.get("tag", "")))


@app.get("/api/campaign")
def api_campaign():
    """Autotest campaign progress (autotest.py writes campaign_status.json)."""
    try:
        s = json.loads(CAMPAIGN_FILE.read_text(encoding="utf-8"))
        s["available"] = True
        s["age_sec"] = max(0, time.time() - CAMPAIGN_FILE.stat().st_mtime)
        return jsonify(s)
    except Exception:
        return jsonify({"available": False})


@app.get("/api/positions")
def api_positions():
    return jsonify(mt5_positions())


@app.get("/api/history")
def api_history():
    return jsonify(mt5_history())


@app.post("/api/command")
def api_command():
    cmd = (request.json or {}).get("cmd", "").upper()
    if cmd not in ("PAUSE", "RESUME", "FLATTEN", "CLEAR_LOCK"):
        return jsonify({"ok": False, "error": "unknown command"}), 400
    try:
        CMD_FILE.write_text(cmd + "\n", encoding="utf-8")
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500
    # wait briefly for the EA acknowledgment (EA polls every 1s)
    ack = ""
    for _ in range(30):
        time.sleep(0.1)
        if not CMD_FILE.exists() and ACK_FILE.exists():
            ack = ACK_FILE.read_text(encoding="utf-8", errors="ignore").strip()
            break
    return jsonify({"ok": True, "ack": ack})


# ----------------------------------------------------------------- web page -
PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>WiseTrader Console</title>
<style>
 body{background:#0f1420;color:#dbe2ef;font:14px/1.45 Segoe UI,Arial,sans-serif;margin:0}
 header{background:#141b2e;padding:14px 22px;display:flex;justify-content:space-between;align-items:center}
 h1{font-size:18px;margin:0;color:#7fb4ff} .muted{color:#7a869c;font-size:12px}
 main{padding:18px 22px;display:grid;grid-template-columns:1fr 1fr;gap:16px;max-width:1200px;margin:auto}
 .card{background:#161e33;border:1px solid #24304e;border-radius:10px;padding:14px 16px}
 .card h2{font-size:13px;margin:0 0 10px;color:#8fa3c8;text-transform:uppercase;letter-spacing:.06em}
 .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}
 .kv{background:#101728;border-radius:8px;padding:8px 10px}
 .kv b{display:block;font-size:11px;color:#7a869c;font-weight:600}
 .kv span{font-size:15px}
 .ok{color:#5ad18a}.warn{color:#ffc861}.bad{color:#ff6b6b}
 button{background:#1f2c4d;border:1px solid #33477a;color:#dbe2ef;border-radius:8px;
        padding:8px 14px;margin-right:8px;cursor:pointer;font-size:13px}
 button:hover{background:#2a3a63} button.red{background:#4d1f28;border-color:#7a3345}
 #log{grid-column:1/-1;height:380px;overflow:auto;background:#0b101c;border-radius:8px;
      padding:10px;font:12px/1.5 Consolas,monospace;white-space:pre-wrap}
 .t-VETO{color:#ffc861}.t-ERROR{color:#ff6b6b}.t-ORDER{color:#5ad18a}
 .t-DECISION{color:#7fb4ff}.t-RISK{color:#ff9d6b}.t-MANAGE{color:#9aa7bf}.t-RECOVER{color:#b48cff}
 .filters button{padding:4px 10px;font-size:12px;margin-right:4px}
 table{width:100%;border-collapse:collapse;font-size:13px}
 td,th{padding:5px 8px;border-bottom:1px solid #24304e;text-align:right}
 th:first-child,td:first-child{text-align:left}
</style></head><body>
<header><h1>WiseTrader Console &mdash; __SYMBOL__ (magic __MAGIC__)</h1>
<div class="muted" id="clock"></div></header>
<main>
 <div class="card"><h2>Bot status</h2><div class="grid" id="status"></div></div>
 <div class="card"><h2>Controls &amp; performance (30d)</h2>
   <div style="margin-bottom:10px">
     <button onclick="cmd('PAUSE')">Pause</button>
     <button onclick="cmd('RESUME')">Resume</button>
     <button class="red" onclick="if(confirm('Close ALL WiseTrader positions?'))cmd('FLATTEN')">Flatten</button>
     <button class="red" onclick="if(confirm('Clear the risk lock?'))cmd('CLEAR_LOCK')">Clear lock</button>
     <span id="ack" class="muted"></span></div>
   <div class="grid" id="perf"></div></div>
 <div class="card" style="grid-column:1/-1"><h2>Test campaign (autotest.py)</h2>
   <div class="grid" id="camp"></div>
   <table id="campruns" style="margin-top:10px"></table></div>
 <div class="card" style="grid-column:1/-1"><h2>Open positions</h2>
   <table id="pos"><tr><th>Ticket</th><th>Type</th><th>Lots</th><th>Open</th>
   <th>Now</th><th>SL</th><th>TP</th><th>P&amp;L</th></tr></table></div>
 <div class="card" style="grid-column:1/-1"><h2>Live journal
   <span class="filters">
    <button onclick="setTag('')">all</button><button onclick="setTag('DECISION')">decisions</button>
    <button onclick="setTag('VETO')">vetoes</button><button onclick="setTag('ORDER')">orders</button>
    <button onclick="setTag('RISK')">risk</button><button onclick="setTag('ERROR')">errors</button>
   </span></h2><div id="log"></div></div>
</main>
<script>
let tag='';
function setTag(t){tag=t;refreshLogs();}
function kv(k,v,c){return `<div class="kv"><b>${k}</b><span class="${c||''}">${v}</span></div>`;}
async function refreshStatus(){
 const s=await (await fetch('/api/status')).json();
 const el=document.getElementById('status');
 if(s.error){el.innerHTML=kv('EA','OFFLINE','bad')+kv('info',s.error);return;}
 el.innerHTML=
  kv('EA',s.ea_alive?'RUNNING':'STALE',s.ea_alive?'ok':'bad')+
  kv('Paused',s.paused?'YES':'no',s.paused?'warn':'ok')+
  kv('Lock',s.lock_txt,s.lock?'bad':'ok')+
  kv('Setup',s.state_txt)+
  kv('Trend',s.trend_txt)+
  kv('Equity',s.equity)+
  kv('Day start',s.day_eq)+
  kv('Peak',s.peak_eq)+
  kv('Streak',s.streak,s.streak>=2?'warn':'')+
  kv('Positions',s.positions)+
  kv('VWAP',s.vwap)+kv('POC',s.poc)+
  kv('Cycle',s.cycle)+
  kv('Analytics',s.analytics_ok?'up to date':'catching up',s.analytics_ok?'ok':'warn')+
  kv('MT5 API',s.mt5_api?'connected':'not available',s.mt5_api?'ok':'warn');
 document.getElementById('clock').textContent='status age: '+Math.round(s.age_sec||0)+'s';
}
async function refreshPerf(){
 const h=await (await fetch('/api/history')).json();
 document.getElementById('perf').innerHTML = h.available ?
  kv('Trades',h.trades)+kv('Wins',h.wins)+kv('Win rate',h.win_rate+'%')+
  kv('Net P&L',h.net_profit,h.net_profit>=0?'ok':'bad')
  : kv('History','install MetaTrader5 pkg','warn');
}
async function refreshPos(){
 const rows=await (await fetch('/api/positions')).json();
 const t=document.getElementById('pos');
 t.innerHTML='<tr><th>Ticket</th><th>Type</th><th>Lots</th><th>Open</th><th>Now</th><th>SL</th><th>TP</th><th>P&L</th></tr>'+
  rows.map(p=>`<tr><td>${p.ticket}</td><td>${p.type}</td><td>${p.volume}</td><td>${p.open}</td>
  <td>${p.current}</td><td>${p.sl}</td><td>${p.tp}</td>
  <td class="${p.profit>=0?'ok':'bad'}">${p.profit.toFixed(2)}</td></tr>`).join('');
}
async function refreshLogs(){
 const rows=await (await fetch('/api/logs?tail=300&tag='+tag)).json();
 const el=document.getElementById('log');
 const atBottom = el.scrollTop+el.clientHeight >= el.scrollHeight-30;
 el.innerHTML=rows.map(r=>`<span class="muted">${r.time}</span> <b class="t-${r.tag}">${r.tag}</b> ${r.msg}`).join('\\n');
 if(atBottom) el.scrollTop=el.scrollHeight;
}
async function cmd(c){
 const r=await (await fetch('/api/command',{method:'POST',
   headers:{'Content-Type':'application/json'},body:JSON.stringify({cmd:c})})).json();
 document.getElementById('ack').textContent=r.ack?('ack: '+r.ack):(r.error||'sent, no ack yet');
 refreshStatus();
}
async function refreshCampaign(){
 const c=await (await fetch('/api/campaign')).json();
 const g=document.getElementById('camp'), t=document.getElementById('campruns');
 if(!c.available){g.innerHTML=kv('Campaign','none yet','warn');t.innerHTML='';return;}
 const running=!c.finished && c.age_sec<600;
 g.innerHTML=
  kv('State',c.finished?'FINISHED':(running?'RUNNING':'STALLED'),c.finished?'ok':(running?'ok':'bad'))+
  kv('Progress',c.done.length+' / '+c.configs.length)+
  kv('Current',c.current||'-')+
  kv('Model',c.model)+
  kv('Window',c.period)+
  kv('Started',c.started)+
  kv('Updated',c.updated);
 t.innerHTML='<tr><th>Config</th><th>Net</th><th>PF</th><th>Trades</th><th>Max DD</th><th>Time</th><th>Error</th></tr>'+
  c.done.map(r=>`<tr><td>${r.config}</td><td class="${parseFloat(r.net_profit)>=0?'ok':'bad'}">${r.net_profit||''}</td>
  <td>${r.profit_factor||''}</td><td>${r.trades||''}</td><td>${r.max_dd||''}</td>
  <td>${r.runtime_s||''}s</td><td class="bad">${r.error||''}</td></tr>`).join('');
}
refreshStatus();refreshPerf();refreshPos();refreshLogs();refreshCampaign();
setInterval(refreshStatus,2000);setInterval(refreshPos,3000);
setInterval(refreshLogs,3000);setInterval(refreshPerf,15000);setInterval(refreshCampaign,5000);
</script></body></html>"""


@app.get("/")
def index():
    return Response(PAGE.replace("__SYMBOL__", SYMBOL).replace("__MAGIC__", str(MAGIC)),
                    mimetype="text/html")


if __name__ == "__main__":
    print(f"WiseTrader Console -> http://127.0.0.1:{PORT}")
    print(f"Bridge folder: {COMMON_FILES}")
    print(f"Campaign file: {CAMPAIGN_FILE}")
    print(f"MetaTrader5 API: {'connected' if MT5_OK else 'NOT available (pip install MetaTrader5)'}")
    app.run(host="127.0.0.1", port=PORT, debug=False)
