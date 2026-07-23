//+------------------------------------------------------------------+
//| WiseTrader - M1Walker.mqh                                        |
//| Base class for features built by walking closed M1 bars          |
//| incrementally (session VWAP, session volume profile).            |
//| Each Execute() call processes at most m_chunk bars so a session  |
//| rebuild after restart never blocks the tick thread.              |
//+------------------------------------------------------------------+
#ifndef WT_M1WALKER_MQH
#define WT_M1WALKER_MQH

#include "Scheduler.mqh"

class CM1Walker : public CJob
  {
protected:
   string            m_sym;
   datetime          m_anchor;      // session start
   datetime          m_last;        // open time of last processed M1 bar
   int               m_chunk;       // max bars per Execute() call
   bool              m_ready;       // caught up at least once this session

   virtual void      OnBar(const MqlRates &r) = 0;   // consume one closed M1 bar
   virtual void      OnReset(void) = 0;              // clear per-session state

public:
                     CM1Walker(void) : m_anchor(0), m_last(0), m_chunk(300), m_ready(false) {}

   void              Setup(const string sym, const int chunk)
     {
      m_sym = sym;
      m_chunk = chunk;
     }

   // Start a new session at 'anchor' (server time)
   void              Reset(const datetime anchor)
     {
      m_anchor = anchor;
      m_last   = 0;
      m_ready  = false;
      OnReset();
     }

   bool              Ready(void) const { return m_ready; }
   datetime          Anchor(void) const { return m_anchor; }

   // CJob: process up to m_chunk closed M1 bars; true when caught up
   virtual bool      Execute(void) override
     {
      if(m_anchor == 0)
         return true;
      int done = 0;
      while(done < m_chunk)
        {
         int shift;
         if(m_last == 0)
            shift = iBarShift(m_sym, PERIOD_M1, m_anchor, false);
         else
            shift = iBarShift(m_sym, PERIOD_M1, m_last, false) - 1;
         if(shift < 1)                    // bar 0 is still forming
           {
            m_ready = true;
            return true;
           }
         MqlRates r[];
         if(CopyRates(m_sym, PERIOD_M1, shift, 1, r) != 1)
            return false;                 // history not ready; retry next call
         if(m_last != 0 && r[0].time <= m_last)
           {
            m_ready = true;               // safety: nothing newer available
            return true;
           }
         if(r[0].time >= m_anchor)
            OnBar(r[0]);
         m_last = r[0].time;
         done++;
        }
      return false;                       // budget used up, more bars remain
     }
  };

#endif // WT_M1WALKER_MQH
