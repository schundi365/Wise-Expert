"""
WiseTrader fetch_data - pull symbol bars from the running MT5 terminal
into CSV for offline analysis (pandas, notebooks, sharing with Claude).

Usage (MT5 must be running and logged in):
  python fetch_data.py                          # XAUUSD M15, last 6 months
  python fetch_data.py EURUSD H1 2026-01-01 2026-07-08
  python fetch_data.py XAUUSD M15 2026-01-01 2026-07-08 out.csv
"""
import sys
from datetime import datetime, timedelta

import MetaTrader5 as mt5

TF = {"M1": mt5.TIMEFRAME_M1, "M5": mt5.TIMEFRAME_M5, "M15": mt5.TIMEFRAME_M15,
      "M30": mt5.TIMEFRAME_M30, "H1": mt5.TIMEFRAME_H1, "H4": mt5.TIMEFRAME_H4,
      "D1": mt5.TIMEFRAME_D1}


def main():
    a = sys.argv[1:]
    symbol = a[0] if len(a) > 0 else "XAUUSD"
    tf_txt = (a[1] if len(a) > 1 else "M15").upper()
    t_to   = datetime.strptime(a[3], "%Y-%m-%d") if len(a) > 3 else datetime.now()
    t_from = datetime.strptime(a[2], "%Y-%m-%d") if len(a) > 2 else t_to - timedelta(days=185)
    out    = a[4] if len(a) > 4 else f"{symbol}_{tf_txt}_{t_from:%Y%m%d}_{t_to:%Y%m%d}.csv"

    if not mt5.initialize():
        sys.exit(f"MT5 initialize failed: {mt5.last_error()} (is the terminal running?)")
    mt5.symbol_select(symbol, True)
    rates = mt5.copy_rates_range(symbol, TF[tf_txt], t_from, t_to)
    mt5.shutdown()
    if rates is None or len(rates) == 0:
        sys.exit("no data returned - check symbol/timeframe/history depth")

    with open(out, "w", encoding="utf-8") as f:
        f.write("time,open,high,low,close,tick_volume,spread,real_volume\n")
        for r in rates:
            f.write(f"{datetime.utcfromtimestamp(r['time']):%Y-%m-%d %H:%M:%S},"
                    f"{r['open']},{r['high']},{r['low']},{r['close']},"
                    f"{r['tick_volume']},{r['spread']},{r['real_volume']}\n")
    print(f"{len(rates)} bars -> {out}")


if __name__ == "__main__":
    main()
