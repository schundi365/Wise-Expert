//+------------------------------------------------------------------+
//| WiseTrader - RelVolume.mqh                                       |
//| F10: relative opening volume - the "in play" filter.             |
//| Compares the signal bar's tick volume to the average volume of   |
//| the SAME time-of-day bar over the past N sessions. Ratio >= 1    |
//| means real participation today; breakouts without fuel are the   |
//| classic fake-break loss. SFI-validated on the ORB strategy.      |
//| Ref: "Low-Frequency Quant Strategies Part 4" (Zarattini 2024).   |
//| Note: XAUUSD volume in MT5 is tick volume - an activity proxy,   |
//| not true volume; the ratio (not the level) is what matters.      |
//+------------------------------------------------------------------+
#ifndef WT_RELVOLUME_MQH
#define WT_RELVOLUME_MQH

class CRelVolume
  {
private:
   string            m_sym;
   ENUM_TIMEFRAMES   m_tf;
   int               m_days;        // sessions in the time-of-day baseline

public:
   void              Init(const string sym, const ENUM_TIMEFRAMES tf, const int days)
     {
      m_sym  = sym;
      m_tf   = tf;
      m_days = MathMax(5, days);
     }

   // Relative volume of the just-closed bar (shift 1) vs the same
   // clock-time bar across prior sessions. Returns -1 when fewer than
   // 5 baseline samples exist (weekends/holidays/history gaps): the
   // caller must treat that as "no gate", never as a veto.
   double            Ratio(void)
     {
      const datetime t1 = iTime(m_sym, m_tf, 1);
      const double   v1 = (double)iVolume(m_sym, m_tf, 1);
      if(t1 == 0 || v1 <= 0)
         return -1.0;
      double sum = 0.0;
      int    n   = 0;
      for(int d = 1; d <= m_days + 10 && n < m_days; d++)   // +10 skips weekends
        {
         const datetime td = t1 - d * 86400;
         const int sh = iBarShift(m_sym, m_tf, td, true);   // exact match only
         if(sh < 0)
            continue;                                       // no such bar (weekend)
         const double v = (double)iVolume(m_sym, m_tf, sh);
         if(v <= 0)
            continue;
         sum += v;
         n++;
        }
      if(n < 5 || sum <= 0)
         return -1.0;
      return v1 / (sum / n);
     }
  };

#endif // WT_RELVOLUME_MQH
