//+------------------------------------------------------------------+
//| WiseTrader - Journal.mqh                                         |
//| Buffered CSV decision/trade journal.                             |
//| Non-blocking design: Log() only appends to an in-memory buffer   |
//| (microseconds); disk writes happen in Flush(), called from       |
//| OnTimer, never from the tick path.                               |
//+------------------------------------------------------------------+
#ifndef WT_JOURNAL_MQH
#define WT_JOURNAL_MQH

class CJournal
  {
private:
   string            m_file;
   string            m_buf[];
   int               m_count;
   bool              m_header_done;

public:
                     CJournal(void) : m_count(0), m_header_done(false) {}

   // 'tag' = test-case name (e.g. "D2_soft_lock"); tagged runs write to
   // their own CSV so regression logs never mix.
   void              Init(const string symbol, const long magic, const string tag = "")
     {
      if(tag == "")
         m_file = StringFormat("WiseTrader_%s_%d.csv", symbol, (int)magic);
      else
         m_file = StringFormat("WiseTrader_%s_%d_%s.csv", symbol, (int)magic, tag);
      ArrayResize(m_buf, 256);
      m_count = 0;
     }

   string            FileName(void) const { return m_file; }

   // tag: DECISION | VETO | ORDER | MANAGE | RISK | RECOVER | ERROR
   void              Log(const string tag, const string msg)
     {
      if(m_count >= ArraySize(m_buf))
         ArrayResize(m_buf, ArraySize(m_buf) + 256);
      m_buf[m_count++] = StringFormat("%s;%s;%s",
                          TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                          tag, msg);
      //--- echo to the Experts tab / tester Journal (low volume, per-bar at most)
      Print("WT ", tag, ": ", msg);
     }

   // Flush buffer to disk. Called from OnTimer and OnDeinit only.
   void              Flush(void)
     {
      if(m_count == 0)
         return;
      //--- FILE_COMMON: one shared location for live charts AND tester runs:
      //--- <Data>\..\Common\Files\WiseTrader_<symbol>_<magic>.csv
      int h = FileOpen(m_file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_COMMON);
      if(h == INVALID_HANDLE)
        {
         Print("WiseTrader journal: cannot open ", m_file, " err=", GetLastError());
         return;
        }
      FileSeek(h, 0, SEEK_END);
      if(!m_header_done && FileTell(h) == 0)
        {
         FileWriteString(h, "time;tag;message\n");
         m_header_done = true;
        }
      for(int i = 0; i < m_count; i++)
         FileWriteString(h, m_buf[i] + "\n");
      FileClose(h);
      m_count = 0;
     }

   int               Pending(void) const { return m_count; }
  };

#endif // WT_JOURNAL_MQH
