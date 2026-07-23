//+------------------------------------------------------------------+
//| WiseTrader - Discipline.mqh                                      |
//| Setup lifecycle FSM and trade authorization. The single gate     |
//| between signal generation and execution: trading is allowed only |
//| after confirmation and only while the setup remains valid.       |
//| Ref: "Engineering Trading Discipline into Code (Part 8)".        |
//+------------------------------------------------------------------+
#ifndef WT_DISCIPLINE_MQH
#define WT_DISCIPLINE_MQH

#include "Config.mqh"

class CDiscipline
  {
private:
   SSettings         m_cfg;
   SSetup            m_setup;
   ENUM_WT_SETUP_STATE m_state;
   int               m_age_bars;

public:
                     CDiscipline(void) : m_state(WT_NO_SETUP), m_age_bars(0) {}

   void              Init(const SSettings &cfg)
     {
      m_cfg = cfg;
      SetupReset(m_setup);
      m_state = WT_NO_SETUP;
     }

   ENUM_WT_SETUP_STATE State(void) const { return m_state; }
   void              GetSetup(SSetup &s) const { s = m_setup; }

   // Register a new setup. Market setups are computed on closed bars, so
   // they are immediately CONFIRMED. Retest setups (chase veto) enter
   // FORMING and wait for the pullback to touch the broken level.
   void              Register(const SSetup &s)
     {
      m_setup    = s;
      m_state    = s.pending_retest ? WT_SETUP_FORMING : WT_SETUP_CONFIRMED;
      m_age_bars = 0;
     }

   // Advance the FSM once per new decision bar.
   void              OnNewBar(const double close, const double high, const double low)
     {
      if(m_state == WT_NO_SETUP || m_state == WT_SETUP_EXPIRED)
         return;
      m_age_bars++;
      //--- price-based expiry: invalidation violated before entry
      const bool invalidated =
         (m_setup.dir == WT_DIR_LONG  && close <= m_setup.invalidation) ||
         (m_setup.dir == WT_DIR_SHORT && close >= m_setup.invalidation);
      //--- time-based expiry: FORMING gets the (longer) retest window,
      //--- confirmed setups the freshness window
      const int max_age = (m_state == WT_SETUP_FORMING)
                          ? m_cfg.retest_max_bars : m_cfg.setup_max_age_bars;
      if(invalidated || m_age_bars > max_age)
        {
         m_state = WT_SETUP_EXPIRED;
         return;
        }
      //--- FORMING: confirm when the pullback touches the retest price
      if(m_state == WT_SETUP_FORMING)
        {
         const bool touched =
            (m_setup.dir == WT_DIR_LONG  && low  <= m_setup.retest_px) ||
            (m_setup.dir == WT_DIR_SHORT && high >= m_setup.retest_px);
         if(touched)
           {
            m_state    = WT_SETUP_CONFIRMED;
            m_age_bars = 0;   // freshness restarts at confirmation
           }
         return;
        }
      if(m_state == WT_SETUP_CONFIRMED)
         m_state = WT_SETUP_ACTIVE;
     }

   void              Consume(void)     // called after execution
     {
      m_state = WT_NO_SETUP;
      SetupReset(m_setup);
     }

   void              Clear(void) { Consume(); }

   bool              InSession(void) const
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(m_cfg.session_start_hour <= m_cfg.session_end_hour)
         return dt.hour >= m_cfg.session_start_hour && dt.hour < m_cfg.session_end_hour;
      //--- overnight window (e.g. 22-06)
      return dt.hour >= m_cfg.session_start_hour || dt.hour < m_cfg.session_end_hour;
     }

   // The authorization verdict. 'lock' comes from the risk manager.
   bool              CanTrade(const ENUM_WT_LOCK lock, string &deny_reason)
     {
      deny_reason = "";
      if(lock != WT_LOCK_NONE)
        { deny_reason = "global lock (" + LockName(lock) + ")"; return false; }
      if(m_state != WT_SETUP_CONFIRMED && m_state != WT_SETUP_ACTIVE)
        { deny_reason = "no confirmed setup"; return false; }
      if(m_age_bars > m_cfg.setup_max_age_bars)
        { deny_reason = "setup stale"; return false; }
      if(!InSession())
        {
         MqlDateTime dt;
         TimeToStruct(TimeCurrent(), dt);
         deny_reason = StringFormat("outside session window (server hour %02d, window %02d-%02d)",
                                    dt.hour, m_cfg.session_start_hour, m_cfg.session_end_hour);
         return false;
        }
      return true;
     }
  };

#endif // WT_DISCIPLINE_MQH
