//+------------------------------------------------------------------+
//| WiseTrader - VolumeProfile.mqh                                   |
//| Session volume profile: POC and 70% Value Area from M1 bars.     |
//| MVP simplification (documented in the spec): volume-at-price is  |
//| built from M1 tick volume distributed evenly across each bar's   |
//| range, instead of raw ticks. This removes the broker tick-cache  |
//| dependency and is fast; Phase 2 can swap in CopyTicksRange().    |
//| Ref: "Automatic Session Volume Profile Builder in MQL5" and      |
//|      "Building a Viewport SnR Volume Profile Indicator".         |
//+------------------------------------------------------------------+
#ifndef WT_VOLPROFILE_MQH
#define WT_VOLPROFILE_MQH

#include "M1Walker.mqh"

class CSessionProfile : public CM1Walker
  {
private:
   double            m_bin;         // bin size in price units
   double            m_base;        // price of bin index 0
   double            m_vol[];       // volume per bin
   int               m_nbins;
   double            m_total_vol;
   bool              m_dirty;       // stats need recompute
   //--- cached stats
   double            m_poc;
   double            m_vah;
   double            m_val;

   int               BinIndex(const double price)
     {
      if(m_nbins == 0)
        {
         m_base = MathFloor(price / m_bin) * m_bin;
         ArrayResize(m_vol, 1);
         m_vol[0] = 0;
         m_nbins = 1;
         return 0;
        }
      int idx = (int)MathFloor((price - m_base) / m_bin);
      if(idx < 0)                       // grow downwards
        {
         const int grow = -idx;
         ArrayResize(m_vol, m_nbins + grow);
         for(int i = m_nbins - 1; i >= 0; i--)
            m_vol[i + grow] = m_vol[i];
         for(int i = 0; i < grow; i++)
            m_vol[i] = 0;
         m_base -= grow * m_bin;
         m_nbins += grow;
         idx = 0;
        }
      else if(idx >= m_nbins)           // grow upwards
        {
         const int newn = idx + 1;
         ArrayResize(m_vol, newn);
         for(int i = m_nbins; i < newn; i++)
            m_vol[i] = 0;
         m_nbins = newn;
        }
      return idx;
     }

   void              Recompute(void)
     {
      m_dirty = false;
      m_poc = 0; m_vah = 0; m_val = 0;
      if(m_nbins == 0 || m_total_vol <= 0)
         return;
      //--- POC = highest-volume bin
      int poc_i = 0;
      for(int i = 1; i < m_nbins; i++)
         if(m_vol[i] > m_vol[poc_i])
            poc_i = i;
      m_poc = m_base + (poc_i + 0.5) * m_bin;
      //--- 70% Value Area: expand around POC toward the larger neighbor
      double acc = m_vol[poc_i];
      int lo = poc_i, hi = poc_i;
      const double target = 0.70 * m_total_vol;
      while(acc < target && (lo > 0 || hi < m_nbins - 1))
        {
         const double below = (lo > 0) ? m_vol[lo - 1] : -1.0;
         const double above = (hi < m_nbins - 1) ? m_vol[hi + 1] : -1.0;
         if(above >= below) { hi++; acc += m_vol[hi]; }
         else               { lo--; acc += m_vol[lo]; }
        }
      m_val = m_base + lo * m_bin;
      m_vah = m_base + (hi + 1) * m_bin;
     }

protected:
   virtual void      OnReset(void) override
     {
      ArrayFree(m_vol);
      m_nbins = 0; m_base = 0; m_total_vol = 0;
      m_poc = 0; m_vah = 0; m_val = 0;
      m_dirty = true;
     }

   virtual void      OnBar(const MqlRates &r) override
     {
      const double v = (double)r.tick_volume;
      if(v <= 0)
         return;
      //--- distribute the bar's volume evenly across the bins it spans
      const int i_lo = BinIndex(r.low);
      const int i_hi = BinIndex(r.high);
      const int span = i_hi - i_lo + 1;
      const double per = v / span;
      for(int i = i_lo; i <= i_hi; i++)
         m_vol[i] += per;
      m_total_vol += v;
      m_dirty = true;
     }

public:
                     CSessionProfile(void) : m_bin(0.20) { OnReset(); }

   virtual string    Name(void) override { return "VolumeProfile"; }

   void              SetBinSize(const double bin) { m_bin = (bin > 0) ? bin : m_bin; }

   bool              HasData(void) { return m_total_vol > 0; }

   double            Poc(void) { if(m_dirty) Recompute(); return m_poc; }
   double            Vah(void) { if(m_dirty) Recompute(); return m_vah; }
   double            Val(void) { if(m_dirty) Recompute(); return m_val; }

   // distance (in price) from 'price' to the nearest of POC/VAH/VAL
   double            NearestLevelDistance(const double price)
     {
      if(m_dirty) Recompute();
      if(m_total_vol <= 0) return DBL_MAX;
      double d = MathAbs(price - m_poc);
      d = MathMin(d, MathAbs(price - m_vah));
      d = MathMin(d, MathAbs(price - m_val));
      return d;
     }
  };

#endif // WT_VOLPROFILE_MQH
