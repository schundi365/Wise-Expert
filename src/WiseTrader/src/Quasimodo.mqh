//+------------------------------------------------------------------+
//| WiseTrader - Quasimodo.mqh                                       |
//| Quasimodo (QM) reversal detection over the confirmed swing       |
//| history maintained by CMarketStructure.                          |
//| Bearish QM: left-shoulder high -> higher head -> close below the |
//| neckline (the low between them) -> price back in the shoulder    |
//| zone. Invalidation above the head; target = neckline projection. |
//| Ref: "Automating Trading Strategies Part 49: The Quasimodo".     |
//+------------------------------------------------------------------+
#ifndef WT_QUASIMODO_MQH
#define WT_QUASIMODO_MQH

#include "Config.mqh"
#include "Structure.mqh"

class CQuasimodo
  {
private:
   string            m_sym;
   ENUM_TIMEFRAMES   m_tf;
   double            m_zone_atr;    // shoulder-zone tolerance in ATR multiples

   // find pattern in swing sequence; returns true and fills setup fields
   bool              ScanBearish(CMarketStructure &ms, const double atr,
                                 const double close, SSetup &s)
     {
      // walk recent swings newest-first looking for: head(high) preceded by
      // neckline(low) preceded by left shoulder(high < head)
      const int n = ms.SwingCount();
      if(n < 3)
         return false;
      SSwing a, b, c;                 // c = older, b = middle, a = newer
      for(int i = 0; i < MathMin(n - 2, 12); i++)
        {
         ms.GetSwing(i, a);
         if(!a.is_high) continue;                 // a = head candidate
         ms.GetSwing(i + 1, b);
         if(b.is_high)  continue;                 // b = neckline low
         ms.GetSwing(i + 2, c);
         if(!c.is_high) continue;                 // c = left shoulder
         if(a.price <= c.price) continue;         // head must exceed shoulder
         //--- neckline must already be broken by a close
         if(close >= b.price) continue;
         //--- price must be back inside the shoulder zone (right shoulder)
         const double zone = m_zone_atr * atr;
         if(MathAbs(close - c.price) > zone) continue;
         //--- fill setup
         s.signal       = WT_SIG_QM;
         s.dir          = WT_DIR_SHORT;
         s.entry        = close;
         s.invalidation = a.price;                          // above the head
         s.target       = b.price - (a.price - b.price);    // neckline projection
         s.evidence     = StringFormat("QM bear LS=%.2f H=%.2f NL=%.2f", c.price, a.price, b.price);
         return true;
        }
      return false;
     }

   bool              ScanBullish(CMarketStructure &ms, const double atr,
                                 const double close, SSetup &s)
     {
      const int n = ms.SwingCount();
      if(n < 3)
         return false;
      SSwing a, b, c;
      for(int i = 0; i < MathMin(n - 2, 12); i++)
        {
         ms.GetSwing(i, a);
         if(a.is_high)  continue;                 // a = head (low)
         ms.GetSwing(i + 1, b);
         if(!b.is_high) continue;                 // b = neckline high
         ms.GetSwing(i + 2, c);
         if(c.is_high)  continue;                 // c = left shoulder (low)
         if(a.price >= c.price) continue;         // head must undercut shoulder
         if(close <= b.price) continue;           // neckline broken up
         const double zone = m_zone_atr * atr;
         if(MathAbs(close - c.price) > zone) continue;
         s.signal       = WT_SIG_QM;
         s.dir          = WT_DIR_LONG;
         s.entry        = close;
         s.invalidation = a.price;
         s.target       = b.price + (b.price - a.price);
         s.evidence     = StringFormat("QM bull LS=%.2f H=%.2f NL=%.2f", c.price, a.price, b.price);
         return true;
        }
      return false;
     }

public:
                     CQuasimodo(void) : m_zone_atr(0.5) {}

   void              Init(const string sym, const ENUM_TIMEFRAMES tf, const double zone_atr)
     {
      m_sym = sym; m_tf = tf;
      m_zone_atr = (zone_atr > 0) ? zone_atr : 0.5;
     }

   // Called once per new bar. Returns true if a QM setup exists now.
   bool              Scan(CMarketStructure &ms, const double atr, SSetup &s)
     {
      const double close = iClose(m_sym, m_tf, 1);
      if(atr <= 0)
         return false;
      SetupReset(s);
      s.bar_time = iTime(m_sym, m_tf, 1);
      if(ScanBearish(ms, atr, close, s)) return true;
      if(ScanBullish(ms, atr, close, s)) return true;
      return false;
     }
  };

#endif // WT_QUASIMODO_MQH
