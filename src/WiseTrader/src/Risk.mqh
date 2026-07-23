//+------------------------------------------------------------------+
//| WiseTrader - Risk.mqh                                            |
//| Capital preservation with veto power over all entries.           |
//| Per-trade sizing, daily loss cutoff, total drawdown hard stop,   |
//| consecutive-loss lock. Counters are persisted in terminal        |
//| global variables so a restart cannot reset the daily limits      |
//| (restart-safe "self-healing lite"; SQLite store is Phase 2).     |
//| Ref: "Risk Manager for Trading Robots (Part I)".                 |
//+------------------------------------------------------------------+
#ifndef WT_RISK_MQH
#define WT_RISK_MQH

#include "Config.mqh"

class CRiskManager
  {
private:
   SSettings         m_cfg;
   string            m_prefix;      // global-variable key prefix
   int               m_atr_fast;    // ATR(14) on decision TF
   int               m_atr_slow;    // ATR(100) baseline for vol regime
   string            m_sizing_note; // evidence of last sizing decision

   double            AtrVal(const int handle)
     {
      double buf[];
      if(handle == INVALID_HANDLE || CopyBuffer(handle, 0, 1, 1, buf) != 1)
         return 0.0;
      return buf[0];
     }

   // worst adverse open gap (|open - prior close|) over the lookback window
   double            MaxRecentGap(void)
     {
      double worst = 0.0;
      const int n = MathMax(m_cfg.gap_lookback, 0);
      for(int i = 1; i <= n; i++)
        {
         const double gap = MathAbs(iOpen(m_cfg.symbol, m_cfg.tf, i)
                                  - iClose(m_cfg.symbol, m_cfg.tf, i + 1));
         if(gap > worst)
            worst = gap;
        }
      return worst;
     }

   // 1.0 at/below vol_full_ratio, linear down to vol_risk_floor at vol_min_ratio
   double            VolRiskScalar(const double atr_fast, const double atr_slow)
     {
      if(atr_fast <= 0 || atr_slow <= 0 || m_cfg.vol_min_ratio <= m_cfg.vol_full_ratio)
         return 1.0;
      const double ratio = atr_fast / atr_slow;
      if(ratio <= m_cfg.vol_full_ratio) return 1.0;
      if(ratio >= m_cfg.vol_min_ratio)  return m_cfg.vol_risk_floor;
      const double t = (ratio - m_cfg.vol_full_ratio)
                     / (m_cfg.vol_min_ratio - m_cfg.vol_full_ratio);
      return 1.0 - t * (1.0 - m_cfg.vol_risk_floor);
     }

   string            Key(const string name) const { return m_prefix + name; }

   double            GetGV(const string name, const double def)
     {
      const string k = Key(name);
      if(GlobalVariableCheck(k))
         return GlobalVariableGet(k);
      GlobalVariableSet(k, def);
      return def;
     }

   void              SetGV(const string name, const double v) { GlobalVariableSet(Key(name), v); }

   long              ServerDay(void) const
     {
      return (long)(TimeCurrent() / 86400);
     }

   // roll daily counters when the server day changes; clears daily locks
   void              NewDayCheck(void)
     {
      const long today = ServerDay();
      if((long)GetGV("day", 0) == today)
         return;
      SetGV("day", (double)today);
      SetGV("day_eq", AccountInfoDouble(ACCOUNT_EQUITY));
      SetGV("streak", 0);
      const int lock = (int)GetGV("lock", 0);
      if(lock == WT_LOCK_DAILY_LOSS || lock == WT_LOCK_STREAK)
         SetGV("lock", 0);
     }

public:
   void              Init(const SSettings &cfg, const bool reset_state = false)
     {
      m_cfg = cfg;
      //--- key by ACCOUNT LOGIN as well: counters from one account must
      //--- never leak into another (stale equity anchors caused phantom
      //--- drawdown locks when the terminal switched accounts)
      m_prefix = StringFormat("WT_%d_%I64d_%s_", (int)m_cfg.magic,
                              AccountInfoInteger(ACCOUNT_LOGIN), m_cfg.symbol);
      m_atr_fast = iATR(m_cfg.symbol, m_cfg.tf, 14);
      m_atr_slow = iATR(m_cfg.symbol, m_cfg.tf, 100);
      m_sizing_note = "";
      if(reset_state)
         ResetState();
      NewDayCheck();
      //--- seed peak equity on first run
      const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(GetGV("peak_eq", 0) < eq)
         SetGV("peak_eq", eq);
     }

   // wipe all persisted risk state for this magic+account+symbol
   void              ResetState(void)
     {
      GlobalVariableDel(Key("day"));
      GlobalVariableDel(Key("day_eq"));
      GlobalVariableDel(Key("streak"));
      GlobalVariableDel(Key("peak_eq"));
      GlobalVariableDel(Key("lock"));
     }

   ENUM_WT_LOCK      Lock(void) { return (ENUM_WT_LOCK)(int)GetGV("lock", 0); }
   bool              Locked(void) { return Lock() != WT_LOCK_NONE; }
   void              SetLock(const ENUM_WT_LOCK l) { SetGV("lock", (double)l); }

   double            DayStartEquity(void) { return GetGV("day_eq", AccountInfoDouble(ACCOUNT_EQUITY)); }
   double            PeakEquity(void)     { return GetGV("peak_eq", AccountInfoDouble(ACCOUNT_EQUITY)); }
   int               LossStreak(void)     { return (int)GetGV("streak", 0); }

   // Fast per-tick guards: returns a lock that requires flattening,
   // or WT_LOCK_NONE. Cheap comparisons only - safe on the tick path.
   ENUM_WT_LOCK      CheckEquityGuards(void)
     {
      NewDayCheck();
      const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      //--- track peak
      if(eq > PeakEquity())
         SetGV("peak_eq", eq);
      //--- total drawdown hard stop (flatten + permanent lock)
      if(eq <= PeakEquity() * (1.0 - m_cfg.max_total_dd_pct / 100.0))
        {
         SetLock(WT_LOCK_TOTAL_DD);
         return WT_LOCK_TOTAL_DD;
        }
      //--- daily loss cutoff (entry lock only, no flatten by default)
      if(eq <= DayStartEquity() * (1.0 - m_cfg.max_daily_loss_pct / 100.0))
         if(Lock() == WT_LOCK_NONE)
            SetLock(WT_LOCK_DAILY_LOSS);
      return WT_LOCK_NONE;
     }

   // called by the EA when a deal closes (from OnTradeTransaction)
   void              OnDealClosed(const double profit)
     {
      NewDayCheck();
      if(profit < 0)
        {
         const int s = LossStreak() + 1;
         SetGV("streak", s);
         if(s >= m_cfg.max_consec_losses && Lock() == WT_LOCK_NONE)
            SetLock(WT_LOCK_STREAK);
        }
      else if(profit > 0)
         SetGV("streak", 0);
     }

   int               OpenPositions(void)
     {
      int n = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         const ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) == m_cfg.symbol &&
            PositionGetInteger(POSITION_MAGIC) == m_cfg.magic)
            n++;
        }
      return n;
     }

   // Entry authorization + position sizing. Returns false with a veto
   // reason, or true with the approved lot size.
   // Loss-per-lot uses OrderCalcProfit (broker-exact: contract size,
   // tick value, account-currency conversion). The old tick-value
   // arithmetic oversized gold by ~10x on some broker specs.
   bool              CanOpen(const ENUM_WT_DIR dir, const double entry, const double sl,
                             double &lots, string &veto)
     {
      veto = "";
      NewDayCheck();
      if(Locked())
        { veto = StringFormat("lock=%d", (int)Lock()); return false; }
      if(OpenPositions() >= m_cfg.max_positions)
        { veto = "max positions"; return false; }

      const double stop_dist = MathAbs(entry - sl);
      if(stop_dist <= 0)
        { veto = "zero stop distance"; return false; }

      //--- adaptive inputs: volatility regime + expected gap slippage
      const double atr_fast = AtrVal(m_atr_fast);
      const double atr_slow = AtrVal(m_atr_slow);
      const double vol_scalar = VolRiskScalar(atr_fast, atr_slow);
      double gap_buf = MathMax(m_cfg.gap_buffer_atr * atr_fast, MaxRecentGap());
      if(gap_buf < 0) gap_buf = 0;
      //--- size as if the stop fills gap_buf beyond the placed SL
      const double eff_stop = stop_dist + gap_buf;

      //--- money at risk (vol-scaled)
      const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      const double risk_money = equity * m_cfg.risk_per_trade_pct / 100.0 * vol_scalar;
      m_sizing_note = StringFormat("vol_ratio=%.2f scalar=%.2f gap_buf=%.5f eff_stop=%.5f",
                                   atr_slow > 0 ? atr_fast / atr_slow : 0.0,
                                   vol_scalar, gap_buf, eff_stop);

      //--- broker-exact loss for 1.0 lot from entry to stop
      double loss_per_lot = 0;
      const ENUM_ORDER_TYPE ot = (dir == WT_DIR_LONG) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(!OrderCalcProfit(ot, m_cfg.symbol, 1.0, entry, sl, loss_per_lot))
        {
         //--- fallback: contract-size arithmetic (still safer than tick math)
         const double contract = SymbolInfoDouble(m_cfg.symbol, SYMBOL_TRADE_CONTRACT_SIZE);
         if(contract <= 0)
           { veto = "OrderCalcProfit failed + bad contract size"; return false; }
         loss_per_lot = stop_dist * contract;
        }
      loss_per_lot = MathAbs(loss_per_lot);
      if(loss_per_lot <= 0)
        { veto = "bad loss/lot"; return false; }

      //--- inflate loss/lot to the gap-adjusted stop distance (linear scale)
      loss_per_lot *= eff_stop / stop_dist;

      lots = risk_money / loss_per_lot;

      //--- broker constraints
      const double vmin  = SymbolInfoDouble(m_cfg.symbol, SYMBOL_VOLUME_MIN);
      const double vmax  = SymbolInfoDouble(m_cfg.symbol, SYMBOL_VOLUME_MAX);
      const double vstep = SymbolInfoDouble(m_cfg.symbol, SYMBOL_VOLUME_STEP);
      if(vstep > 0)
         lots = MathFloor(lots / vstep) * vstep;
      if(lots < vmin)
        { veto = StringFormat("size %.2f < broker min %.2f (risk too small for stop)", lots, vmin); return false; }
      if(lots > vmax)
         lots = vmax;

      //--- final sanity clamp: worst-case loss must not exceed budget by >20%
      const double worst = lots * loss_per_lot;
      if(worst > risk_money * 1.2)
        { veto = StringFormat("sizing sanity clamp: worst-case %.2f > budget %.2f", worst, risk_money); return false; }
      return true;
     }

   // evidence string from the last CanOpen sizing pass (for the journal)
   string            SizingNote(void) const { return m_sizing_note; }
  };

#endif // WT_RISK_MQH
