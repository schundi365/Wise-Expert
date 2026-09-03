//+------------------------------------------------------------------+
//| WiseTrader - SpreadGate.mqh                                      |
//| F58: execution-cost gate. Rolling mean/stddev of the per-bar     |
//| spread; a break firing while the CURRENT spread is an outlier    |
//| high (Z above threshold) is entering into "toxic flow" - wide,   |
//| thin, expensive fills that eat the edge on a market/stop entry.  |
//| Directionless, cheap, and INDEPENDENT of the price-outlier mask  |
//| (that masks price candles; this watches the bid/ask cost only).  |
//|                                                                  |
//| Clean-room reimplementation of the rolling-spread-Z idea. Uses   |
//| MT5's per-bar spread series (CopySpread, points). Follows the    |
//| RelVolume convention: returns a sentinel when the sample is too  |
//| small so the caller treats "no data" as NO gate, never a veto.   |
//+------------------------------------------------------------------+
#ifndef WT_SPREADGATE_MQH
#define WT_SPREADGATE_MQH

// Sentinel: not enough spread samples to judge -> caller must stand down.
#define WT_SPREAD_Z_NA (-1000.0)

class CSpreadGate
  {
private:
   string            m_sym;
   ENUM_TIMEFRAMES   m_tf;
   int               m_period;      // rolling window (bars) for mean/stddev

public:
   void              Init(const string sym, const ENUM_TIMEFRAMES tf, const int period)
     {
      m_sym    = sym;
      m_tf     = tf;
      m_period = MathMax(10, period);
     }

   // Z-score of the just-closed bar's spread (shift 1) vs the rolling
   // window behind it. Positive Z = wider-than-usual spread. Returns
   // WT_SPREAD_Z_NA when fewer than 10 valid samples exist or the window
   // has no dispersion (flat spread) - never a fabricated veto value.
   double            ZScore(void)
     {
      int sp[];
      ArraySetAsSeries(sp, true);
      //--- shift 1 is the signal bar; pull the window that precedes it
      const int need = m_period + 1;
      const int got  = CopySpread(m_sym, m_tf, 0, need, sp);
      if(got < 12)                      // need >=1 current + >=10 baseline
         return WT_SPREAD_Z_NA;

      const double cur = (double)sp[1]; // just-closed bar
      if(cur <= 0)
         return WT_SPREAD_Z_NA;

      //--- baseline = bars 2..got-1 (exclude the bar being judged)
      double sum = 0.0, sum2 = 0.0;
      int    n   = 0;
      for(int i = 2; i < got; i++)
        {
         const double v = (double)sp[i];
         if(v <= 0)
            continue;                   // skip zero-spread gaps
         sum  += v;
         sum2 += v * v;
         n++;
        }
      if(n < 10)
         return WT_SPREAD_Z_NA;

      const double mean = sum / n;
      const double var  = sum2 / n - mean * mean;
      if(var <= 0.0)
         return WT_SPREAD_Z_NA;         // flat spread window: nothing to judge
      const double sd = MathSqrt(var);
      return (cur - mean) / sd;
     }
  };

#endif // WT_SPREADGATE_MQH
