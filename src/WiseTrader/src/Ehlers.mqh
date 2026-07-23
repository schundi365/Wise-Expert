//+------------------------------------------------------------------+
//| WiseTrader - Ehlers.mqh                                          |
//| Roofing Filter (48-bar high-pass + 10-bar Super Smoother) and    |
//| Even Better Sinewave cycle oscillator on the decision timeframe. |
//| Incremental recursion: O(1) per closed bar after warmup.         |
//| Ref: "Digital Signal Processing for Traders: Ehlers' Filters".   |
//+------------------------------------------------------------------+
#ifndef WT_EHLERS_MQH
#define WT_EHLERS_MQH

#include "Scheduler.mqh"

class CEhlers : public CJob
  {
private:
   string            m_sym;
   ENUM_TIMEFRAMES   m_tf;
   int               m_warmup;      // bars required before Ready()
   //--- recursion state
   datetime          m_last;        // open time of last processed closed bar
   double            m_c1, m_c2;    // close[t-1], close[t-2]
   double            m_hp1, m_hp2;  // high-pass history
   double            m_f1, m_f2;    // roofing filter history
   int               m_bars_done;
   //--- coefficients
   double            m_a1hp;        // high-pass alpha
   double            m_cc1, m_cc2, m_cc3; // super smoother coeffs
   //--- outputs
   double            m_wave;        // Even Better Sinewave in [-1, 1]
   double            m_wave_prev;   // previous bar's wave (turn detection)
   double            m_filt;        // roofing filter value

   void              Step(const double close)
     {
      m_wave_prev = m_wave;
      //--- 2-pole high-pass (48-bar cutoff)
      const double hp = (1 - m_a1hp / 2) * (1 - m_a1hp / 2) * (close - 2 * m_c1 + m_c2)
                        + 2 * (1 - m_a1hp) * m_hp1
                        - (1 - m_a1hp) * (1 - m_a1hp) * m_hp2;
      //--- 10-bar Super Smoother of the high-pass output
      const double filt = m_cc1 * (hp + m_hp1) / 2 + m_cc2 * m_f1 + m_cc3 * m_f2;
      //--- Even Better Sinewave normalization
      const double wave = (filt + m_f1 + m_f2) / 3.0;
      const double pwr  = (filt * filt + m_f1 * m_f1 + m_f2 * m_f2) / 3.0;
      m_wave = (pwr > 0) ? wave / MathSqrt(pwr) : 0.0;
      m_filt = filt;
      //--- shift history
      m_c2 = m_c1;   m_c1 = close;
      m_hp2 = m_hp1; m_hp1 = hp;
      m_f2 = m_f1;   m_f1 = filt;
      m_bars_done++;
     }

public:
                     CEhlers(void) : m_warmup(100), m_last(0), m_c1(0), m_c2(0),
                                     m_hp1(0), m_hp2(0), m_f1(0), m_f2(0),
                                     m_bars_done(0), m_wave(0), m_wave_prev(0), m_filt(0) {}

   virtual string    Name(void) override { return "Ehlers"; }

   void              Init(const string sym, const ENUM_TIMEFRAMES tf)
     {
      m_sym = sym;
      m_tf  = tf;
      //--- high-pass coefficient, 48-bar cutoff
      const double ang = 0.707 * 2.0 * M_PI / 48.0;
      m_a1hp = (MathCos(ang) + MathSin(ang) - 1.0) / MathCos(ang);
      //--- Super Smoother coefficients, 10-bar
      const double a1 = MathExp(-1.414 * M_PI / 10.0);
      const double b1 = 2.0 * a1 * MathCos(1.414 * M_PI / 10.0);
      m_cc2 = b1;
      m_cc3 = -a1 * a1;
      m_cc1 = 1.0 - m_cc2 - m_cc3;
     }

   bool              Ready(void) const { return m_bars_done >= m_warmup; }
   double            Wave(void)     const { return m_wave; }      // >0 cycle up, <0 cycle down
   double            WavePrev(void) const { return m_wave_prev; } // previous closed bar
   double            Filt(void)  const { return m_filt; }

   // CJob: consume any newly closed decision-TF bars (chunked)
   virtual bool      Execute(void) override
     {
      const int MAX_STEPS = 200;
      int steps = 0;
      while(steps < MAX_STEPS)
        {
         int shift;
         if(m_last == 0)
           {
            const int total = Bars(m_sym, m_tf);
            if(total < m_warmup + 5)
               return false;             // history not ready yet
            shift = MathMin(total - 2, m_warmup + 150); // warmup window
           }
         else
           {
            shift = iBarShift(m_sym, m_tf, m_last, false) - 1;
           }
         if(shift < 1)
            return true;                 // caught up (bar 0 forming)
         const datetime t = iTime(m_sym, m_tf, shift);
         if(m_last != 0 && t <= m_last)
            return true;
         Step(iClose(m_sym, m_tf, shift));
         m_last = t;
         steps++;
        }
      return false;                      // more bars remain, resume next call
     }
  };

#endif // WT_EHLERS_MQH
