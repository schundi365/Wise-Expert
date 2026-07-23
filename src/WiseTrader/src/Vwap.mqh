//+------------------------------------------------------------------+
//| WiseTrader - Vwap.mqh                                            |
//| Session-anchored VWAP with volume-weighted deviation bands.      |
//| Incremental: one M1 bar per step, O(1) per bar.                  |
//| Ref: "Building an Object-Oriented Session VWAP Engine in MQL5".  |
//+------------------------------------------------------------------+
#ifndef WT_VWAP_MQH
#define WT_VWAP_MQH

#include "M1Walker.mqh"

class CSessionVwap : public CM1Walker
  {
private:
   double            m_sum_pv;      // sum(price*vol)
   double            m_sum_v;       // sum(vol)
   double            m_sum_p2v;     // sum(price^2*vol)

protected:
   virtual void      OnReset(void) override
     {
      m_sum_pv = 0; m_sum_v = 0; m_sum_p2v = 0;
     }

   virtual void      OnBar(const MqlRates &r) override
     {
      const double p = (r.high + r.low + r.close) / 3.0;   // typical price
      const double v = (double)r.tick_volume;
      if(v <= 0)
         return;
      m_sum_pv  += p * v;
      m_sum_v   += v;
      m_sum_p2v += p * p * v;
     }

public:
                     CSessionVwap(void) { OnReset(); }

   virtual string    Name(void) override { return "VWAP"; }

   bool              HasData(void) const { return m_sum_v > 0; }

   double            Value(void) const
     {
      return (m_sum_v > 0) ? m_sum_pv / m_sum_v : 0.0;
     }

   // volume-weighted standard deviation around VWAP
   double            Deviation(void) const
     {
      if(m_sum_v <= 0)
         return 0.0;
      const double vwap = m_sum_pv / m_sum_v;
      const double var  = m_sum_p2v / m_sum_v - vwap * vwap;
      return (var > 0) ? MathSqrt(var) : 0.0;
     }

   double            Upper(const double k) const { return Value() + k * Deviation(); }
   double            Lower(const double k) const { return Value() - k * Deviation(); }
  };

#endif // WT_VWAP_MQH
