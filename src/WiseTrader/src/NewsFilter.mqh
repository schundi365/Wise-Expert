//+------------------------------------------------------------------+
//| WiseTrader - NewsFilter.mqh                                      |
//| F18: economic-calendar blackout. Blocks NEW entries inside a     |
//| +/- window around high-impact events for the symbol currencies. |
//| Open positions are untouched (stops already handle them).       |
//| The MT5 Strategy Tester has no calendar data: the filter then    |
//| reports "not blocked" and is transparently inactive in backtest. |
//| Ref: "MQL5 Economic Calendar News Filter" Parts 3-4.             |
//+------------------------------------------------------------------+
#ifndef WT_NEWSFILTER_MQH
#define WT_NEWSFILTER_MQH

#include "Config.mqh"

class CNewsFilter
  {
private:
   SSettings         m_cfg;
   string            m_base;        // symbol base currency (e.g. XAU)
   string            m_profit;      // symbol profit currency (e.g. USD)
   //--- 1-minute result caches: calendar queries are not free
   datetime          m_cache_time;
   bool              m_cache_blocked;
   string            m_cache_reason;
   datetime          m_up_cache_time;
   bool              m_up_cache_hit;
   string            m_up_cache_reason;

   bool              CurrencyRelevant(const string ccy) const
     {
      return (ccy == m_base || ccy == m_profit);
     }

public:
   void              Init(const SSettings &cfg)
     {
      m_cfg    = cfg;
      m_base   = SymbolInfoString(m_cfg.symbol, SYMBOL_CURRENCY_BASE);
      m_profit = SymbolInfoString(m_cfg.symbol, SYMBOL_CURRENCY_PROFIT);
      m_cache_time    = 0;
      m_cache_blocked = false;
      m_cache_reason  = "";
      m_up_cache_time = 0;
      m_up_cache_hit  = false;
      m_up_cache_reason = "";
     }

   // true = a relevant high-impact event starts within the next 'minutes'
   // (v2.4 pre-news flatten). Inactive in the Strategy Tester (no calendar).
   bool              Upcoming(const int minutes, string &reason)
     {
      reason = "";
      if(minutes <= 0)
         return false;
      const datetime now = TimeCurrent();
      if(now - m_up_cache_time < 60)   // reuse result for 60 seconds
        { reason = m_up_cache_reason; return m_up_cache_hit; }
      m_up_cache_time   = now;
      m_up_cache_hit    = false;
      m_up_cache_reason = "";

      MqlCalendarValue values[];
      if(!CalendarValueHistory(values, now, now + minutes * 60))
         return false;
      const int n = ArraySize(values);
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
            continue;
         MqlCalendarCountry country;
         if(!CalendarCountryById(ev.country_id, country))
            continue;
         if(!CurrencyRelevant(country.currency))
            continue;
         m_up_cache_hit    = true;
         m_up_cache_reason = StringFormat("%s (%s) @ %s", ev.name, country.currency,
                             TimeToString(values[i].time, TIME_MINUTES));
         break;
        }
      reason = m_up_cache_reason;
      return m_up_cache_hit;
     }

   // true = stand down (a relevant high-impact event is inside the window)
   bool              Blocked(string &reason)
     {
      reason = "";
      if(!m_cfg.news_enabled || m_cfg.news_block_min <= 0)
         return false;

      const datetime now = TimeCurrent();
      if(now - m_cache_time < 60)      // reuse result for 60 seconds
        { reason = m_cache_reason; return m_cache_blocked; }
      m_cache_time    = now;
      m_cache_blocked = false;
      m_cache_reason  = "";

      const int win = m_cfg.news_block_min * 60;
      MqlCalendarValue values[];
      //--- fails in the Strategy Tester (no calendar data): filter inactive
      if(!CalendarValueHistory(values, now - win, now + win))
         return false;
      const int n = ArraySize(values);
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
            continue;
         MqlCalendarCountry country;
         if(!CalendarCountryById(ev.country_id, country))
            continue;
         if(!CurrencyRelevant(country.currency))
            continue;
         m_cache_blocked = true;
         m_cache_reason  = StringFormat("news window: %s (%s) @ %s",
                           ev.name, country.currency,
                           TimeToString(values[i].time, TIME_MINUTES));
         break;
        }
      reason = m_cache_reason;
      return m_cache_blocked;
     }
  };

#endif // WT_NEWSFILTER_MQH
