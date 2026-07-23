@echo off
rem WiseTrader Console launcher
rem Optional overrides:  set WT_SYMBOL=XAUUSD  set WT_MAGIC=20260707  set WT_PORT=5088
cd /d "%~dp0"
python -m pip install -q -r requirements.txt
start "" http://127.0.0.1:5088
python dashboard.py
pause
