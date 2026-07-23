//+------------------------------------------------------------------+
//| WiseTrader - Scheduler.mqh                                       |
//| Cooperative, time-budgeted scheduler.                            |
//|                                                                  |
//| MQL5 EAs are single-threaded, so "non-blocking" means no module  |
//| may hog the thread. Every heavy module implements CJob and does  |
//| its work in small incremental chunks: Execute() returns true     |
//| when caught up for the current bar, false if more work remains.  |
//| The scheduler drains pending jobs under a microsecond budget;    |
//| whatever doesn't fit in this tick finishes on the next tick or   |
//| the 1-second timer. Trade management never waits on analytics.   |
//+------------------------------------------------------------------+
#ifndef WT_SCHEDULER_MQH
#define WT_SCHEDULER_MQH

class CJob
  {
public:
   virtual bool      Execute(void) = 0;   // true = done for current bar
   virtual string    Name(void)    = 0;
  };

class CScheduler
  {
private:
   CJob             *m_jobs[];
   bool              m_pending[];
   int               m_n;

public:
                     CScheduler(void) : m_n(0) {}

   int               Register(CJob *job)
     {
      ArrayResize(m_jobs, m_n + 1);
      ArrayResize(m_pending, m_n + 1);
      m_jobs[m_n] = job;
      m_pending[m_n] = false;
      return m_n++;
     }

   // Mark every job dirty (called once per new decision bar)
   void              MarkAllPending(void)
     {
      for(int i = 0; i < m_n; i++)
         m_pending[i] = true;
     }

   // Run pending jobs in registration order under a time budget.
   // Returns true when nothing is pending anymore.
   bool              RunPending(const ulong budget_us)
     {
      const ulong start = GetMicrosecondCount();
      for(int i = 0; i < m_n; i++)
        {
         if(!m_pending[i])
            continue;
         while(m_pending[i])
           {
            if(m_jobs[i].Execute())
               m_pending[i] = false;
            if(GetMicrosecondCount() - start >= budget_us)
               return AllDone();
           }
        }
      return AllDone();
     }

   bool              AllDone(void) const
     {
      for(int i = 0; i < m_n; i++)
         if(m_pending[i])
            return false;
      return true;
     }
  };

#endif // WT_SCHEDULER_MQH
