//+------------------------------------------------------------------+
//| WiseTraderORB.mq5 - Opening Range Breakout system for US stocks  |
//| Implementation of the volatility-adjusted momentum intraday      |
//| system from "Low-Frequency Quantitative Strategies in MetaTrader |
//| 5 (Part 4)" (Zarattini et al. 2024, Swiss Finance Institute).    |
//|                                                                  |
//| Daily cycle (all times US Eastern):                              |
//|  09:30      opening range (OR) forms (first M5 candle default)   |
//|  OR close   scan universe: eligibility screen -> relative OR     |
//|             volume filter ("Stocks in Play") -> rank by relVol   |
//|             -> take top N -> stop order at OR high/low in the    |
//|             direction of the OR candle bias                      |
//|  16:00      flatten everything, delete untriggered orders        |
//|                                                                  |
//| Stop-loss: 10% of 14-day ATR. No take-profit: winners run to     |
//| the bell (documented P/L ratio ~1:4). Risk is split so a full    |
//| stop-out across all N symbols costs InpRiskPercent of equity.    |
//+------------------------------------------------------------------+
#property copyright "Wise Trader project"
#property version   "1.10"
#property description "SFI Opening Range Breakout system for stocks: trades 'Stocks in Play' (abnormal opening volume) with volatility-adjusted stops and end-of-day flat."

#include <Trade\Trade.mqh>

//--- inputs ---------------------------------------------------------
input group "Session (US Eastern Time)"
input ENUM_TIMEFRAMES InpORTimeframe   = PERIOD_M5; // Opening range timeframe
input int      InpOpenHourET           = 9;         // Market open hour (ET)
input int      InpOpenMinET            = 30;        // Market open minute (ET)
input int      InpCloseHourET          = 15;        // Flatten hour (ET)
input int      InpCloseMinET           = 55;        // Flatten minute (ET)
input int      InpETGMTOffset          = -4;        // ET vs GMT: -4 summer (EDT), -5 winter (EST)

input group "Universe & filters (SFI defaults)"
input string   InpSymbols              = "";        // CSV symbol list ("" = whole Market Watch)
input double   InpPriceMin             = 5.0;       // Min share price
input double   InpMinAvgDailyVolume    = 1000000;   // Min 14-day avg daily volume
input double   InpMinATR               = 0.50;      // Min 14-day ATR ($)
input double   InpRelVolThreshold      = 1.0;       // Min relative opening volume (1.0 = 100%)
input int      InpMaxSymbols           = 3;         // Trade top N by relative volume

input group "Risk"
input double   InpRiskPercent          = 1.0;       // Total risk % (split across N symbols)
input double   InpStopAtrFraction      = 0.10;      // Stop = fraction of 14-day ATR
input double   InpMaxDailyLoss         = 3.0;       // Skip new trades after % daily loss
input double   InpMaxTotalDD           = 10.0;      // Flatten + lock at % from peak equity
input long     InpMagic                = 20260708;  // Magic number
input bool     InpResetRiskState       = false;     // Reset persisted risk state on init

//--- globals --------------------------------------------------------
CTrade   g_trade;
string   g_universe[];          // parsed symbol list ("" input = use Market Watch)
int      g_universe_n = 0;
datetime g_or_start = 0, g_or_end = 0, g_close = 0;  // today's session (server time)
int      g_et_day = -1;         // current ET day-of-year marker
bool     g_scanned = false;     // today's scan done
bool     g_flat_done = false;   // today's close-out done
string   g_gv_prefix;
string   g_log_file;
string   g_log_buf[];
int      g_log_n = 0;

struct SCandidate
  {
   string   name;
   double   rel_vol;
   int      bias;      // +1 bull, -1 bear, 0 neutral
   double   or_high;
   double   or_low;
   double   atr14;
  };

//+------------------------------------------------------------------+
//| Journal (buffered, Common\Files, echoed to Experts tab)          |
//+------------------------------------------------------------------+
void Log(const string tag, const string msg)
  {
   if(g_log_n >= ArraySize(g_log_buf))
      ArrayResize(g_log_buf, g_log_n + 128);
   g_log_buf[g_log_n++] = StringFormat("%s;%s;%s",
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), tag, msg);
   Print("ORB ", tag, ": ", msg);
  }

void FlushLog(void)
  {
   if(g_log_n == 0)
      return;
   int h = FileOpen(g_log_file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   if(FileTell(h) == 0)
      FileWriteString(h, "time;tag;message\n");
   for(int i = 0; i < g_log_n; i++)
      FileWriteString(h, g_log_buf[i] + "\n");
   FileClose(h);
   g_log_n = 0;
  }

//+------------------------------------------------------------------+
//| Risk state in global variables (keyed by magic+account)          |
//+------------------------------------------------------------------+
double GetGV(const string k, const double def)
  {
   const string key = g_gv_prefix + k;
   if(GlobalVariableCheck(key))
      return GlobalVariableGet(key);
   GlobalVariableSet(key, def);
   return def;
  }
void SetGV(const string k, const double v) { GlobalVariableSet(g_gv_prefix + k, v); }

bool TotalDDLocked(void) { return GetGV("lock", 0) > 0; }

//+------------------------------------------------------------------+
//| ET <-> server time. Server offset vs GMT is measured live, so    |
//| only the ET-vs-GMT offset (DST) is a user input.                 |
//+------------------------------------------------------------------+
long ServerMinusET(void)
  {
   const long server_gmt = (long)(TimeTradeServer() - TimeGMT());
   return server_gmt - (long)InpETGMTOffset * 3600;
  }

void ComputeSession(void)
  {
   const long off = ServerMinusET();
   const datetime et_now = (datetime)((long)TimeTradeServer() - off);
   const datetime et_day = (datetime)((long)et_now - (long)et_now % 86400);
   const datetime et_open  = (datetime)((long)et_day + InpOpenHourET * 3600 + InpOpenMinET * 60);
   const datetime et_close = (datetime)((long)et_day + InpCloseHourET * 3600 + InpCloseMinET * 60);
   g_or_start = (datetime)((long)et_open + off);
   g_or_end   = (datetime)((long)g_or_start + PeriodSeconds(InpORTimeframe));
   g_close    = (datetime)((long)et_close + off);
   MqlDateTime dt;
   TimeToStruct(et_now, dt);
   if(dt.day_of_year != g_et_day)
     {
      g_et_day = dt.day_of_year;
      g_scanned = false;
      g_flat_done = false;
      //--- roll daily equity anchor
      SetGV("day_eq", AccountInfoDouble(ACCOUNT_EQUITY));
      if(dt.day_of_week >= 1 && dt.day_of_week <= 5)
         Log("RECOVER", StringFormat("new ET day, OR %s-%s close %s (server)",
             TimeToString(g_or_start, TIME_MINUTES), TimeToString(g_or_end, TIME_MINUTES),
             TimeToString(g_close, TIME_MINUTES)));
     }
  }

//+------------------------------------------------------------------+
//| Universe helpers                                                 |
//+------------------------------------------------------------------+
int UniverseSize(void)
  {
   return (g_universe_n > 0) ? g_universe_n : SymbolsTotal(true);
  }
string UniverseSymbol(const int i)
  {
   return (g_universe_n > 0) ? g_universe[i] : SymbolName(i, true);
  }

// bar volume: prefer exchange real volume, fall back to tick volume
long BarVolume(const MqlRates &r)
  {
   return (r.real_volume > 0) ? r.real_volume : r.tick_volume;
  }

//+------------------------------------------------------------------+
//| Daily scan: eligibility -> relative OR volume -> rank -> trade   |
//+------------------------------------------------------------------+
void Scan(void)
  {
   SCandidate cands[];
   int ncand = 0;
   const int total = UniverseSize();

   for(int i = 0; i < total; i++)
     {
      const string sym = UniverseSymbol(i);

      //--- eligibility: 14-day price/volume/ATR screen on D1
      MqlRates d1[];
      if(CopyRates(sym, PERIOD_D1, 1, 14, d1) < 14)
         continue;
      double avg_vol = 0, atr = 0;
      for(int j = 0; j < 14; j++)
        {
         avg_vol += (double)BarVolume(d1[j]);
         const double prev_close = (j > 0) ? d1[j - 1].close : d1[j].open;
         atr += MathMax(d1[j].high - d1[j].low,
                MathMax(MathAbs(d1[j].high - prev_close), MathAbs(d1[j].low - prev_close)));
        }
      avg_vol /= 14.0;
      atr /= 14.0;
      const double price = SymbolInfoDouble(sym, SYMBOL_BID);
      if(price < InpPriceMin || avg_vol < InpMinAvgDailyVolume || atr < InpMinATR)
         continue;

      //--- today's opening range bar
      MqlRates orb[];
      if(CopyRates(sym, InpORTimeframe, g_or_start, (datetime)((long)g_or_end - 1), orb) < 1)
         continue;

      //--- historical baseline: same OR window over previous 14 trading days
      long hist[14];
      int found = 0;
      for(int d = 1; d <= 30 && found < 14; d++)
        {
         const datetime hs = (datetime)((long)g_or_start - d * 86400);
         MqlRates hr[];
         if(CopyRates(sym, InpORTimeframe, hs, (datetime)((long)hs + PeriodSeconds(InpORTimeframe) - 1), hr) >= 1)
            hist[found++] = BarVolume(hr[0]);
        }
      if(found < 14)
         continue;
      double base = 0;
      for(int j = 0; j < found; j++)
         base += (double)hist[j];
      base /= found;
      if(base <= 0)
         continue;
      const double rel_vol = (double)BarVolume(orb[0]) / base;
      if(rel_vol < InpRelVolThreshold)
         continue;

      //--- candidate
      ArrayResize(cands, ncand + 1);
      cands[ncand].name    = sym;
      cands[ncand].rel_vol = rel_vol;
      cands[ncand].bias    = (orb[0].close > orb[0].open) ? 1 : (orb[0].close < orb[0].open ? -1 : 0);
      cands[ncand].or_high = orb[0].high;
      cands[ncand].or_low  = orb[0].low;
      cands[ncand].atr14   = atr;
      ncand++;
     }

   //--- rank by relative volume, descending (insertion sort, N is small)
   for(int i = 1; i < ncand; i++)
     {
      SCandidate key = cands[i];
      int j = i - 1;
      while(j >= 0 && cands[j].rel_vol < key.rel_vol)
        {
         cands[j + 1] = cands[j];
         j--;
        }
      cands[j + 1] = key;
     }

   const int to_trade = MathMin(ncand, InpMaxSymbols);
   Log("DECISION", StringFormat("scan: %d in universe, %d in play, trading top %d",
       total, ncand, to_trade));
   for(int i = 0; i < to_trade; i++)
      PlaceORB(cands[i], to_trade);
  }

//+------------------------------------------------------------------+
//| Place one ORB trade: stop order at range edge, 0.1*ATR14 stop    |
//+------------------------------------------------------------------+
void PlaceORB(SCandidate &c, const int n_traded)
  {
   if(c.bias == 0)
     {
      Log("VETO", c.name + ": neutral opening bias (doji)");
      return;
     }
   const bool  is_long = (c.bias > 0);
   const double entry  = is_long ? c.or_high : c.or_low;
   const double sldist = InpStopAtrFraction * c.atr14;
   const double sl     = is_long ? entry - sldist : entry + sldist;

   //--- size: split risk so all N stops together cost InpRiskPercent
   //--- OrderCalcProfit = broker-exact loss/lot (contract size + currency)
   const double vmin  = SymbolInfoDouble(c.name, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(c.name, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(c.name, SYMBOL_VOLUME_STEP);
   if(sldist <= 0)
     {
      Log("ERROR", c.name + ": bad stop distance");
      return;
     }
   double loss_per_lot = 0;
   const ENUM_ORDER_TYPE ot = is_long ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(ot, c.name, 1.0, entry, sl, loss_per_lot))
     {
      const double contract = SymbolInfoDouble(c.name, SYMBOL_TRADE_CONTRACT_SIZE);
      if(contract <= 0) { Log("ERROR", c.name + ": sizing failed"); return; }
      loss_per_lot = sldist * contract;
     }
   loss_per_lot = MathAbs(loss_per_lot);
   if(loss_per_lot <= 0) { Log("ERROR", c.name + ": bad loss/lot"); return; }
   const double risk_money = AccountInfoDouble(ACCOUNT_EQUITY)
                             * (InpRiskPercent / 100.0) / n_traded;
   double lots = risk_money / loss_per_lot;
   if(vstep > 0)
      lots = MathFloor(lots / vstep) * vstep;
   if(lots < vmin)
     {
      Log("VETO", StringFormat("%s: size %.2f below broker min %.2f", c.name, lots, vmin));
      return;
     }
   if(lots > vmax)
      lots = vmax;

   const int digits = (int)SymbolInfoInteger(c.name, SYMBOL_DIGITS);
   const double n_entry = NormalizeDouble(entry, digits);
   const double n_sl    = NormalizeDouble(sl, digits);
   const string comment = StringFormat("ORB|rv=%.2f", c.rel_vol);
   const double ask = SymbolInfoDouble(c.name, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(c.name, SYMBOL_BID);

   bool ok;
   if(is_long)
     {
      if(ask >= n_entry)
         ok = g_trade.Buy(lots, c.name, 0.0, n_sl, 0.0, comment);
      else
         ok = g_trade.BuyStop(lots, n_entry, c.name, n_sl, 0.0, ORDER_TIME_SPECIFIED, g_close, comment);
     }
   else
     {
      if(bid <= n_entry)
         ok = g_trade.Sell(lots, c.name, 0.0, n_sl, 0.0, comment);
      else
         ok = g_trade.SellStop(lots, n_entry, c.name, n_sl, 0.0, ORDER_TIME_SPECIFIED, g_close, comment);
     }
   if(ok)
      Log("ORDER", StringFormat("%s %s %.2f lots @ %.2f sl %.2f relVol %.2f",
          c.name, is_long ? "LONG" : "SHORT", lots, n_entry, n_sl, c.rel_vol));
   else
      Log("ERROR", StringFormat("%s order failed rc=%u", c.name, g_trade.ResultRetcode()));
  }

//+------------------------------------------------------------------+
//| Close everything of ours: positions and pending orders           |
//+------------------------------------------------------------------+
void FlattenAll(const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      g_trade.PositionClose(ticket);
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      g_trade.OrderDelete(ticket);
     }
   Log("RISK", "flatten: " + reason);
  }

//+------------------------------------------------------------------+
int OnInit(void)
  {
   g_gv_prefix = StringFormat("WTORB_%d_%I64d_", (int)InpMagic,
                              AccountInfoInteger(ACCOUNT_LOGIN));
   if(InpResetRiskState)
     {
      GlobalVariableDel(g_gv_prefix + "day_eq");
      GlobalVariableDel(g_gv_prefix + "peak_eq");
      GlobalVariableDel(g_gv_prefix + "lock");
     }
   g_log_file = StringFormat("WiseTraderORB_%d.csv", (int)InpMagic);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(50);

   //--- parse CSV universe
   g_universe_n = 0;
   string parts[];
   const int n = StringSplit(InpSymbols, ',', parts);
   for(int i = 0; i < n; i++)
     {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      if(parts[i] == "")
         continue;
      if(!SymbolSelect(parts[i], true))
        {
         Print("WiseTraderORB: symbol not found: ", parts[i]);
         return INIT_PARAMETERS_INCORRECT;
        }
      ArrayResize(g_universe, g_universe_n + 1);
      g_universe[g_universe_n++] = parts[i];
     }

   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(GetGV("peak_eq", 0) < eq)
      SetGV("peak_eq", eq);

   EventSetTimer(5);
   Log("RECOVER", StringFormat("init: universe=%s lock=%s equity=%.2f",
       g_universe_n > 0 ? IntegerToString(g_universe_n) + " symbols" : "Market Watch",
       TotalDDLocked() ? "TOTAL_DD" : "none", eq));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   FlushLog();
   Comment("");
  }

//+------------------------------------------------------------------+
//| Everything is time-driven: 5-second timer, no tick work at all.  |
//+------------------------------------------------------------------+
void OnTimer(void)
  {
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   //--- total drawdown hard stop
   if(eq > GetGV("peak_eq", eq))
      SetGV("peak_eq", eq);
   if(!TotalDDLocked() && eq <= GetGV("peak_eq", eq) * (1.0 - InpMaxTotalDD / 100.0))
     {
      SetGV("lock", 1);
      FlattenAll("total drawdown hard stop");
      SendNotification("WiseTraderORB: TOTAL DD hard stop - flattened and locked");
     }

   ComputeSession();

   const datetime now = TimeCurrent();

   //--- end of day flat (always runs, even when locked)
   if(!g_flat_done && now >= g_close)
     {
      FlattenAll("end of session");
      g_flat_done = true;
     }

   //--- daily scan at OR completion
   if(!g_scanned && now >= g_or_end && now < g_close)
     {
      g_scanned = true;   // one attempt per day, success or not
      if(TotalDDLocked())
         Log("VETO", "scan skipped: TOTAL_DD lock (clear " + g_gv_prefix + "lock to resume)");
      else if(eq <= GetGV("day_eq", eq) * (1.0 - InpMaxDailyLoss / 100.0))
         Log("VETO", "scan skipped: daily loss limit");
      else
         Scan();
     }

   FlushLog();
   Comment(StringFormat("WiseTraderORB | OR %s-%s | flat %s (server)\nToday: %s | Lock: %s | Equity: %.2f",
           TimeToString(g_or_start, TIME_MINUTES), TimeToString(g_or_end, TIME_MINUTES),
           TimeToString(g_close, TIME_MINUTES),
           g_scanned ? "scanned" : "waiting for opening range",
           TotalDDLocked() ? "TOTAL_DD" : "none", eq));
  }
//+------------------------------------------------------------------+
