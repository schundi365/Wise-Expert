//+------------------------------------------------------------------+
//| WiseTrader - Execution.mqh                                       |
//| CExecutor: order placement with bounded retries.                 |
//| CTradeManager: breakeven + trailing management, restart-aware by |
//| construction - state is inferred from broker-side SL vs entry,   |
//| so a terminal restart resumes management exactly where it was    |
//| and the stop can never regress.                                  |
//| Ref: "Engineering a Self-Healing EA (Part 3)".                   |
//+------------------------------------------------------------------+
#ifndef WT_EXECUTION_MQH
#define WT_EXECUTION_MQH

#include <Trade\Trade.mqh>
#include "Config.mqh"
#include "Structure.mqh"
#include "Journal.mqh"

class CExecutor
  {
private:
   CTrade            m_trade;
   SSettings         m_cfg;
   CJournal         *m_journal;
   int               m_digits;
   datetime          m_last_mod_fail;   // modify-rejection log throttle

public:
   void              Init(const SSettings &cfg, CJournal *journal)
     {
      m_cfg = cfg;
      m_journal = journal;
      m_last_mod_fail = 0;
      m_digits = (int)SymbolInfoInteger(m_cfg.symbol, SYMBOL_DIGITS);
      m_trade.SetExpertMagicNumber(m_cfg.magic);
      m_trade.SetDeviationInPoints(30);
      m_trade.SetTypeFillingBySymbol(m_cfg.symbol);
     }

   double            Norm(const double price) const { return NormalizeDouble(price, m_digits); }

   // market entry with bounded retries; returns true on fill
   bool              OpenMarket(const ENUM_WT_DIR dir, const double lots,
                                const double sl, const double tp, const string comment)
     {
      for(int attempt = 1; attempt <= 3; attempt++)
        {
         bool ok;
         if(dir == WT_DIR_LONG)
            ok = m_trade.Buy(lots, m_cfg.symbol, 0.0, Norm(sl), Norm(tp), comment);
         else
            ok = m_trade.Sell(lots, m_cfg.symbol, 0.0, Norm(sl), Norm(tp), comment);
         const uint rc = m_trade.ResultRetcode();
         if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
           {
            m_journal.Log("ORDER", StringFormat("filled %s %.2f lots sl=%.2f tp=%.2f [%s]",
                          dir == WT_DIR_LONG ? "BUY" : "SELL", lots, sl, tp, comment));
            return true;
           }
         m_journal.Log("ERROR", StringFormat("order attempt %d retcode=%u", attempt, rc));
         //--- retry only on transient conditions
         if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED &&
            rc != TRADE_RETCODE_PRICE_OFF)
            break;
         Sleep(200);
        }
      m_journal.Log("ERROR", "order aborted after retries");
      return false;
     }

   // flatten everything for this symbol+magic (total-DD hard stop)
   void              CloseAll(const string reason)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         const ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_cfg.symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_cfg.magic) continue;
         if(!m_trade.PositionClose(ticket))
            m_journal.Log("ERROR", StringFormat("close %I64u failed rc=%u", ticket, m_trade.ResultRetcode()));
        }
      m_journal.Log("RISK", "FLATTEN ALL: " + reason);
     }

   bool              Modify(const ulong ticket, const double sl, const double tp)
     {
      if(m_trade.PositionModify(ticket, Norm(sl), Norm(tp)))
         return true;
      //--- v2.2: rejected modifies were silent; log, throttled to 30s so a
      //--- broker rejection loop cannot flood the journal from the tick path
      const datetime now = TimeCurrent();
      if(now - m_last_mod_fail >= 30)
        {
         m_last_mod_fail = now;
         m_journal.Log("ERROR", StringFormat("modify #%I64u sl=%.2f tp=%.2f rejected rc=%u",
                       ticket, sl, tp, m_trade.ResultRetcode()));
        }
      return false;
     }

   // ---- pending orders (v2.1 early entry) -------------------------
   // GTC placement; lifecycle (expiry, invalidation, replacement) is
   // owned by the EA new-bar logic, which is restart-safe by scanning
   // broker-side orders rather than trusting runtime memory.

   bool              PlaceLimit(const ENUM_WT_DIR dir, const double lots, const double price,
                                const double sl, const double tp, const string comment)
     {
      const bool ok = (dir == WT_DIR_LONG)
         ? m_trade.BuyLimit(lots, Norm(price), m_cfg.symbol, Norm(sl), Norm(tp),
                            ORDER_TIME_GTC, 0, comment)
         : m_trade.SellLimit(lots, Norm(price), m_cfg.symbol, Norm(sl), Norm(tp),
                             ORDER_TIME_GTC, 0, comment);
      m_journal.Log(ok ? "ORDER" : "ERROR",
                    StringFormat("limit %s %.2f @ %.2f sl=%.2f tp=%.2f rc=%u [%s]",
                    dir == WT_DIR_LONG ? "BUY" : "SELL", lots, price, sl, tp,
                    m_trade.ResultRetcode(), comment));
      return ok;
     }

   bool              PlaceStop(const ENUM_WT_DIR dir, const double lots, const double price,
                               const double sl, const double tp, const string comment)
     {
      const bool ok = (dir == WT_DIR_LONG)
         ? m_trade.BuyStop(lots, Norm(price), m_cfg.symbol, Norm(sl), Norm(tp),
                           ORDER_TIME_GTC, 0, comment)
         : m_trade.SellStop(lots, Norm(price), m_cfg.symbol, Norm(sl), Norm(tp),
                            ORDER_TIME_GTC, 0, comment);
      m_journal.Log(ok ? "ORDER" : "ERROR",
                    StringFormat("stop %s %.2f @ %.2f sl=%.2f tp=%.2f rc=%u [%s]",
                    dir == WT_DIR_LONG ? "BUY" : "SELL", lots, price, sl, tp,
                    m_trade.ResultRetcode(), comment));
      return ok;
     }

   int               PendingCount(void)
     {
      int n = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         const ulong ticket = OrderGetTicket(i);
         if(ticket == 0) continue;
         if(OrderGetString(ORDER_SYMBOL) == m_cfg.symbol &&
            OrderGetInteger(ORDER_MAGIC) == m_cfg.magic)
            n++;
        }
      return n;
     }

   void              CancelPending(const string reason)
     {
      int cancelled = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         const ulong ticket = OrderGetTicket(i);
         if(ticket == 0) continue;
         if(OrderGetString(ORDER_SYMBOL) != m_cfg.symbol) continue;
         if(OrderGetInteger(ORDER_MAGIC) != m_cfg.magic) continue;
         if(m_trade.OrderDelete(ticket))
            cancelled++;
         else
            m_journal.Log("ERROR", StringFormat("cancel #%I64u failed rc=%u",
                          ticket, m_trade.ResultRetcode()));
        }
      if(cancelled > 0)
         m_journal.Log("ORDER", StringFormat("cancelled %d pending: %s", cancelled, reason));
     }

   // close part of a position, respecting broker volume constraints;
   // returns false (harmlessly) when the position is too small to split
   bool              ClosePartial(const ulong ticket, const double pct)
     {
      if(pct <= 0 || pct >= 100) return false;
      if(!PositionSelectByTicket(ticket)) return false;
      const double vol   = PositionGetDouble(POSITION_VOLUME);
      const double vmin  = SymbolInfoDouble(m_cfg.symbol, SYMBOL_VOLUME_MIN);
      const double vstep = SymbolInfoDouble(m_cfg.symbol, SYMBOL_VOLUME_STEP);
      double part = vol * pct / 100.0;
      if(vstep > 0)
         part = MathFloor(part / vstep) * vstep;
      //--- both the closed part and the remainder must satisfy the minimum
      if(part < vmin || vol - part < vmin)
         return false;
      if(!m_trade.PositionClosePartial(ticket, part))
        {
         m_journal.Log("ERROR", StringFormat("partial close %I64u failed rc=%u",
                       ticket, m_trade.ResultRetcode()));
         return false;
        }
      m_journal.Log("MANAGE", StringFormat("#%I64u partial close %.2f of %.2f lots",
                    ticket, part, vol));
      return true;
     }
  };

//+------------------------------------------------------------------+
//| Trade manager: runs every tick, must stay fast.                  |
//+------------------------------------------------------------------+
class CTradeManager
  {
private:
   SSettings         m_cfg;
   CExecutor        *m_exec;
   CJournal         *m_journal;
   int               m_atr_handle;
   double            m_min_step;    // minimum SL improvement to bother the server

   double            Atr(void)
     {
      double buf[];
      if(CopyBuffer(m_atr_handle, 0, 1, 1, buf) != 1)
         return 0.0;
      return buf[0];
     }

public:
   void              Init(const SSettings &cfg, CExecutor *exec, CJournal *journal)
     {
      m_cfg = cfg;
      m_exec = exec;
      m_journal = journal;
      m_atr_handle = iATR(m_cfg.symbol, m_cfg.tf, 14);
      const double point = SymbolInfoDouble(m_cfg.symbol, SYMBOL_POINT);
      m_min_step = 10 * point;
     }

   int               AtrHandle(void) const { return m_atr_handle; }
   double            AtrValue(void)        { return Atr(); }

   // Per-tick management. Iterates only this EA's positions; each check
   // is O(1). No analytics, no file IO, no waiting on other modules.
   void              Manage(CMarketStructure &ms)
     {
      const double atr = Atr();
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         const ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_cfg.symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_cfg.magic) continue;

         const long   type  = PositionGetInteger(POSITION_TYPE);
         const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
         const double sl    = PositionGetDouble(POSITION_SL);
         const double tp    = PositionGetDouble(POSITION_TP);
         const double cur   = PositionGetDouble(POSITION_PRICE_CURRENT);
         const bool   is_long = (type == POSITION_TYPE_BUY);

         //--- restart-aware state inference: BE already applied iff the
         //--- stop is at/beyond entry. No runtime memory needed.
         const bool be_done = (sl > 0) && (is_long ? (sl >= entry) : (sl <= entry));

         double new_sl = sl;
         bool   partial_due = false;

         //--- 1) breakeven (+ partial exit). v2.2: with wide structure stops
         //--- a pure R-multiple trigger can sit most of the way to TP, so
         //--- the stop also arms at be_atr_trigger*ATR of profit.
         if(!be_done)
           {
            const double risk = MathAbs(entry - sl);
            if(sl <= 0 || risk <= 0) continue;
            double trigger = m_cfg.breakeven_r * risk;
            if(m_cfg.be_atr_trigger > 0 && atr > 0)
               trigger = MathMin(trigger, m_cfg.be_atr_trigger * atr);
            if((is_long && cur - entry >= trigger) ||
               (!is_long && entry - cur >= trigger))
              {
               const double spread = SymbolInfoDouble(m_cfg.symbol, SYMBOL_ASK)
                                   - SymbolInfoDouble(m_cfg.symbol, SYMBOL_BID);
               new_sl = is_long ? entry + spread : entry - spread;
               partial_due = (m_cfg.partial_pct > 0);
              }
           }
         //--- 2) trailing (only after breakeven)
         else
           {
            double cand = 0.0;
            if(m_cfg.trail_mode == WT_TRAIL_ATR && atr > 0)
               cand = is_long ? cur - m_cfg.trail_atr_mult * atr
                              : cur + m_cfg.trail_atr_mult * atr;
            else if(m_cfg.trail_mode == WT_TRAIL_STRUCTURE)
               cand = is_long ? ms.ProtectiveLow(cur) : ms.ProtectiveHigh(cur);
            if(cand > 0)
               new_sl = is_long ? MathMax(sl, cand) : MathMin(sl, cand);
           }

         //--- 3) progressive profit lock (v2.2): once lock_start_pct of the
         //--- entry->TP distance is covered, the stop locks lock_pct of the
         //--- open profit - independent of BE state, never regresses.
         if(m_cfg.lock_start_pct > 0 && m_cfg.lock_pct > 0 && tp > 0)
           {
            const double tp_dist = MathAbs(tp - entry);
            const double prog    = is_long ? (cur - entry) : (entry - cur);
            if(tp_dist > 0 && prog >= m_cfg.lock_start_pct / 100.0 * tp_dist)
              {
               const double lock = is_long
                                   ? entry + m_cfg.lock_pct / 100.0 * prog
                                   : entry - m_cfg.lock_pct / 100.0 * prog;
               new_sl = is_long ? MathMax(new_sl, lock) : MathMin(new_sl, lock);
               //--- if the lock is what first carries the stop past entry,
               //--- bank the partial here (same once-only invariant)
               if(!be_done)
                  partial_due = (m_cfg.partial_pct > 0);
              }
           }

         //--- invariant: the stop never regresses; only act on real moves
         const bool improved = is_long ? (new_sl > sl + m_min_step)
                                       : (new_sl < sl - m_min_step);
         if(improved)
           {
            if(m_exec.Modify(ticket, new_sl, tp))
              {
               m_journal.Log("MANAGE", StringFormat("#%I64u SL %.2f -> %.2f %s",
                             ticket, sl, new_sl, be_done ? "trail" : "breakeven"));
               //--- partial exit banks profit at the BE trigger. SL is moved
               //--- FIRST: once it sits at/beyond entry, be_done inference
               //--- guarantees this branch never repeats (restart-safe, no
               //--- double partial even if the close itself fails).
               if(partial_due)
                  m_exec.ClosePartial(ticket, m_cfg.partial_pct);
              }
           }
        }
     }
  };

#endif // WT_EXECUTION_MQH
