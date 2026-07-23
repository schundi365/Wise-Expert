//+------------------------------------------------------------------+
//| WiseTrader - Structure.mqh                                       |
//| Swing validation and BOS / CHoCH detection on the decision TF.   |
//| Explicit, reproducible rules; duplicate-signal suppression by    |
//| requiring a new confirmed swing between breaks.                  |
//| Ref: "Building an Internal and External Market Structure         |
//|       Indicator" (S1-S4 swings, BOS, CHoCH).                     |
//+------------------------------------------------------------------+
#ifndef WT_STRUCTURE_MQH
#define WT_STRUCTURE_MQH

#include "Config.mqh"

struct SSwing
  {
   double            price;
   datetime          time;
   bool              is_high;
  };

struct SStructureEvent
  {
   ENUM_WT_SIGNAL    type;          // WT_SIG_BOS or WT_SIG_CHOCH
   ENUM_WT_DIR       dir;
   double            level;         // broken swing level
   datetime          bar_time;
  };

class CMarketStructure
  {
private:
   string            m_sym;
   ENUM_TIMEFRAMES   m_tf;
   int               m_wing;        // bars on each side for a valid swing
   datetime          m_last_bar;    // last processed closed bar
   //--- swing history (most recent last)
   SSwing            m_swings[];
   int               m_nswings;
   //--- structure state
   ENUM_WT_DIR       m_trend;       // WT_DIR_NONE until first break
   double            m_last_high;   // last confirmed, not-yet-broken swing high
   double            m_last_low;
   bool              m_high_live;   // false after the level is broken
   bool              m_low_live;
   //--- last event of the current bar (consumed by signal engine)
   SStructureEvent   m_event;
   bool              m_has_event;

   void              PushSwing(const double price, const datetime t, const bool is_high)
     {
      const int MAXS = 64;
      if(m_nswings >= MAXS)
        {
         for(int i = 1; i < m_nswings; i++)
            m_swings[i - 1] = m_swings[i];
         m_nswings--;
        }
      ArrayResize(m_swings, m_nswings + 1);
      m_swings[m_nswings].price   = price;
      m_swings[m_nswings].time    = t;
      m_swings[m_nswings].is_high = is_high;
      m_nswings++;
      if(is_high) { m_last_high = price; m_high_live = true; }
      else        { m_last_low  = price; m_low_live  = true; }
     }

   // is bar at 'shift' a confirmed swing high/low? (fractal, wing bars each side)
   bool              IsSwingHigh(const int shift)
     {
      const double h = iHigh(m_sym, m_tf, shift);
      for(int k = 1; k <= m_wing; k++)
         if(iHigh(m_sym, m_tf, shift + k) >= h || iHigh(m_sym, m_tf, shift - k) > h)
            return false;
      return true;
     }

   bool              IsSwingLow(const int shift)
     {
      const double l = iLow(m_sym, m_tf, shift);
      for(int k = 1; k <= m_wing; k++)
         if(iLow(m_sym, m_tf, shift + k) <= l || iLow(m_sym, m_tf, shift - k) < l)
            return false;
      return true;
     }

public:
                     CMarketStructure(void) : m_wing(3), m_last_bar(0), m_nswings(0),
                                              m_trend(WT_DIR_NONE),
                                              m_last_high(0), m_last_low(0),
                                              m_high_live(false), m_low_live(false),
                                              m_has_event(false) {}

   void              Init(const string sym, const ENUM_TIMEFRAMES tf, const int wing)
     {
      m_sym = sym; m_tf = tf;
      m_wing = MathMax(2, wing);
      //--- warmup: seed swings from recent history
      const int total = Bars(m_sym, m_tf);
      const int deep  = MathMin(total - m_wing - 2, 400);
      for(int shift = deep; shift > m_wing; shift--)
        {
         if(IsSwingHigh(shift)) PushSwing(iHigh(m_sym, m_tf, shift), iTime(m_sym, m_tf, shift), true);
         if(IsSwingLow(shift))  PushSwing(iLow(m_sym, m_tf, shift),  iTime(m_sym, m_tf, shift), false);
        }
      m_last_bar = iTime(m_sym, m_tf, 1);
     }

   ENUM_WT_DIR       Trend(void)    const { return m_trend; }
   double            LastHigh(void) const { return m_last_high; }
   double            LastLow(void)  const { return m_last_low; }
   int               SwingCount(void) const { return m_nswings; }

   void              GetSwing(const int i_from_end, SSwing &out) const
     {
      const int idx = m_nswings - 1 - i_from_end;
      if(idx >= 0 && idx < m_nswings)
         out = m_swings[idx];
     }

   bool              HasEvent(void) const { return m_has_event; }
   void              GetEvent(SStructureEvent &e) const { e = m_event; }
   void              ClearEvent(void) { m_has_event = false; }

   // most recent confirmed swing low below price (long invalidation anchor)
   double            ProtectiveLow(const double below)
     {
      for(int i = m_nswings - 1; i >= 0; i--)
         if(!m_swings[i].is_high && m_swings[i].price < below)
            return m_swings[i].price;
      return 0.0;
     }

   double            ProtectiveHigh(const double above)
     {
      for(int i = m_nswings - 1; i >= 0; i--)
         if(m_swings[i].is_high && m_swings[i].price > above)
            return m_swings[i].price;
      return 0.0;
     }

   bool              HighLive(void) const { return m_high_live; }
   bool              LowLive(void)  const { return m_low_live;  }

   // Break detection against the live levels for a given close price.
   // Mutates structure state (trend flip, level consumed) and stores the
   // event. Called with the M15 close by Update(), or with an M1 close by
   // the EA in WT_ENTRY_M1_CLOSE mode - the live-level flags make the two
   // paths naturally deduplicate. Returns true when a break fired.
   bool              BreakCheck(const double c, const datetime t)
     {
      if(m_high_live && m_last_high > 0 && c > m_last_high)
        {
         m_event.type     = (m_trend == WT_DIR_SHORT) ? WT_SIG_CHOCH : WT_SIG_BOS;
         m_event.dir      = WT_DIR_LONG;
         m_event.level    = m_last_high;
         m_event.bar_time = t;
         m_has_event      = true;
         m_trend          = WT_DIR_LONG;
         m_high_live      = false;        // suppress duplicates until a new swing forms
         return true;
        }
      if(m_low_live && m_last_low > 0 && c < m_last_low)
        {
         m_event.type     = (m_trend == WT_DIR_LONG) ? WT_SIG_CHOCH : WT_SIG_BOS;
         m_event.dir      = WT_DIR_SHORT;
         m_event.level    = m_last_low;
         m_event.bar_time = t;
         m_has_event      = true;
         m_trend          = WT_DIR_SHORT;
         m_low_live       = false;
         return true;
        }
      return false;
     }

   // Mark a live level as consumed after a stop-order fill at that level
   // (the fill IS the break; prevents a duplicate signal on bar close).
   void              ConsumeLevel(const ENUM_WT_DIR dir)
     {
      if(dir == WT_DIR_LONG)  { m_high_live = false; m_trend = WT_DIR_LONG;  }
      if(dir == WT_DIR_SHORT) { m_low_live  = false; m_trend = WT_DIR_SHORT; }
     }

   // Called once per new decision bar (bar 1 just closed). Cheap: O(wing).
   void              Update(void)
     {
      m_has_event = false;
      const datetime t1 = iTime(m_sym, m_tf, 1);
      if(t1 == m_last_bar)
         return;
      m_last_bar = t1;

      //--- 1) confirm swing at shift = wing+1 (needs 'wing' closed bars after it)
      const int s = m_wing + 1;
      if(IsSwingHigh(s)) PushSwing(iHigh(m_sym, m_tf, s), iTime(m_sym, m_tf, s), true);
      if(IsSwingLow(s))  PushSwing(iLow(m_sym, m_tf, s),  iTime(m_sym, m_tf, s), false);

      //--- 2) break detection on the just-closed bar
      BreakCheck(iClose(m_sym, m_tf, 1), t1);
     }
  };

#endif // WT_STRUCTURE_MQH
