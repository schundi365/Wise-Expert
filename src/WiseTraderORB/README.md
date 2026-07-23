# WiseTraderORB — Opening Range Breakout for US Stocks

Implements the Swiss Finance Institute ORB system (Zarattini et al., 2024) from
"Low-Frequency Quantitative Strategies in MetaTrader 5 (Part 4)":
trade only "Stocks in Play" (abnormal opening volume), stop order at the first
5-minute range edge in the direction of the opening candle, stop-loss at 10% of
the 14-day ATR, no take-profit, everything flat before the closing bell.
Low frequency by design: expect roughly 5–6 trades per month.

## Requirements

- A broker (or the free MetaQuotes-Demo account) offering US stocks in MT5.
- Real exchange volume matters: the relative-volume edge is built on it.
  The EA falls back to tick volume if real volume is absent (CFD feeds) —
  works, but weaker evidence behind it.

## Setup

1. Copy the `WiseTraderORB` folder into `MQL5\Experts\`, compile (F7).
2. In Market Watch, show the stocks you want scanned (e.g. top 30 NASDAQ by
   volume), or set `InpSymbols` to a CSV list like `AAPL,NVDA,TSLA,AMZN,MSFT`.
3. Attach to ANY chart (M5 of one of your stocks is convenient — the EA is
   time-driven and scans the whole universe regardless of the chart).
4. Set `InpETGMTOffset`: **-4** during US daylight saving (roughly Mar–Nov),
   **-5** in winter. Everything else about server time is handled automatically.

## Daily cycle (all ET)

| Time | Action |
|---|---|
| 09:30–09:35 | Opening range forms (first M5 candle) |
| 09:35 | Scan: price ≥ $5, 14d avg volume ≥ 1M, 14d ATR ≥ $0.50 → relative OR volume ≥ 100% of its 14-day baseline → rank, take top `InpMaxSymbols` → stop orders at OR high (bull candle) / OR low (bear candle), doji = skip |
| intraday | Stop-loss = 0.1 × ATR(14d). No TP, no trailing — winners run |
| 15:55 | Flatten all positions, delete untriggered orders |

## Risk

- `InpRiskPercent` (1%) is the TOTAL risk if every traded symbol stops out; it
  is split across the N symbols traded that day.
- Daily loss guard (3%): skips the day's scan. Total DD guard (10%): flattens
  and locks (`WTORB_<magic>_<login>_lock` global variable; delete it or use
  `InpResetRiskState` to resume).

## Monitoring

Journal: Experts tab live (`ORB DECISION: ...`) and
`Common\Files\WiseTraderORB_<magic>.csv`. Chart corner shows today's session
times, scan state, and lock status.

## Backtesting

Like the article: optimize per symbol (set `InpSymbols` to one symbol per pass)
on M5, OHLC modelling is sufficient. Multi-symbol scanning also works in a
single tester run if the symbols are in Market Watch, but per-symbol passes are
what the article's Sharpe ranking used.

Not financial advice. The SFI evidence is for single US stocks with real
exchange volume, 2016–2023; validate on your broker's data before funding it.
