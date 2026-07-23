//+------------------------------------------------------------------+
//| WiseTrader - Outliers.mqh                                        |
//| F16: modified Z-score outlier bar mask (median/MAD on true       |
//| range - one freak bar cannot skew its own baseline).             |
//| Two uses:                                                        |
//|  1. IsOutlier(1): the just-closed bar is a news/flash candle -   |
//|     suppress signal generation on it (fake BOS levels).          |
//|  2. CleanAtr(): ATR from the most recent non-outlier true        |
//|     ranges, so one NFP candle does not double the stop floor,    |
//|     the TP cap and the QM zone for the next 14 bars.             |
//| Works in the Strategy Tester (unlike the calendar news filter).  |
//| Ref: "Detecting Outlier Bars (Modified Z-Score on OHLCV)".       |
//+------------------------------------------------------------------+
#ifndef WT_OUTLIERS_MQH
#define WT_OUTLIERS_MQH

class COutlierMask
  {
private:
   string            m_sym;
   ENUM_TIMEFRAMES   m_tf;
   int               m_win;         // baseline window, bars
   //--- per-bar cache: median/MAD are recomputed once per new bar
   datetime          m_cache_bar;
   double            m_med;
   double            m_mad;

   double            TrueRange(const int shift) const
     {
      const double h  = iHigh(m_sym, m_tf, shift);
      const double l  = iLow(m_sym, m_tf, shift);
      const double pc = iClose(m_sym, m_tf, shift + 1);
      return MathMax(h - l, MathMax(MathAbs(h - pc), MathAbs(l - pc)));
     }

   static double     Median(double &a[], const int n)
     {
      ArraySort(a);
      return (n % 2 == 1) ? a[n / 2] : 0.5 * (a[n / 2 - 1] + a[n / 2]);
     }

   // baseline over bars 2..win+1 (excludes the bar being tested at
   // shift 1, so a spike never sits inside its own reference window)
   bool              Refresh(void)
     {
      const datetime t1 = iTime(m_sym, m_tf, 1);
      if(t1 == m_cache_bar)
         return (m_mad >= 0);
      if(Bars(m_sym, m_tf) < m_win + 3)
         return false;
      double tr[];
      ArrayResize(tr, m_win);
      for(int i = 0; i < m_win; i++)
         tr[i] = TrueRange(2 + i);
      double tmp[];
      ArrayCopy(tmp, tr);
      m_med = Median(tmp, m_win);
      for(int i = 0; i < m_win; i++)
         tr[i] = MathAbs(tr[i] - m_med);
      m_mad = Median(tr, m_win);
      m_cache_bar = t1;
      return true;
     }

public:
                     COutlierMask(void) : m_win(100), m_cache_bar(0),
                                          m_med(0), m_mad(-1) {}

   void              Init(const string sym, const ENUM_TIMEFRAMES tf, const int win = 100)
     {
      m_sym = sym;
      m_tf  = tf;
      m_win = MathMax(30, win);
      m_cache_bar = 0;
      m_mad = -1;
     }

   // modified Z-score of the bar's true range; 0 when stats unavailable
   double            ZScore(const int shift)
     {
      if(!Refresh() || m_mad <= 0)
         return 0.0;
      return 0.6745 * (TrueRange(shift) - m_med) / m_mad;
     }

   bool              IsOutlier(const int shift, const double z_thresh)
     {
      if(z_thresh <= 0)
         return false;
      return ZScore(shift) > z_thresh;
     }

   // ATR(period) from the most recent non-outlier true ranges within
   // the baseline window. Returns 0 when unavailable (caller falls
   // back to the raw iATR value).
   double            CleanAtr(const int period, const double z_thresh)
     {
      if(z_thresh <= 0 || !Refresh() || m_mad <= 0)
         return 0.0;
      double sum = 0.0;
      int    n   = 0;
      for(int shift = 1; shift <= m_win && n < period; shift++)
        {
         const double tr = TrueRange(shift);
         const double z  = 0.6745 * (tr - m_med) / m_mad;
         if(z > z_thresh)
            continue;                 // masked: news/flash bar
         sum += tr;
         n++;
        }
      if(n < period)
         return 0.0;
      return sum / n;
     }
  };

#endif // WT_OUTLIERS_MQH
