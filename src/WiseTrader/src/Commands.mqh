//+------------------------------------------------------------------+
//| WiseTrader - Commands.mqh                                        |
//| File-based command bridge for the external dashboard.            |
//| The dashboard writes a one-line command file into Common\Files;  |
//| the EA polls it on the 1-second timer (never on the tick path),  |
//| executes, deletes the file, and writes an acknowledgment.        |
//|                                                                  |
//| Commands:  PAUSE | RESUME | FLATTEN | CLEAR_LOCK                 |
//| Status:    the EA also drops a status JSON every timer tick so   |
//|            the dashboard can read state without MT5 API calls.   |
//+------------------------------------------------------------------+
#ifndef WT_COMMANDS_MQH
#define WT_COMMANDS_MQH

#include "Config.mqh"
#include "Journal.mqh"

class CCommandBridge
  {
private:
   string            m_cmd_file;    // dashboard -> EA
   string            m_ack_file;    // EA -> dashboard (last command result)
   string            m_status_file; // EA -> dashboard (state snapshot)
   bool              m_paused;      // dashboard-requested entry pause

   void              WriteAck(const string cmd, const string result)
     {
      int h = FileOpen(m_ack_file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h == INVALID_HANDLE) return;
      FileWriteString(h, StringFormat("%s;%s;%s\n",
                      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), cmd, result));
      FileClose(h);
     }

public:
                     CCommandBridge(void) : m_paused(false) {}

   void              Init(const string symbol, const long magic)
     {
      const string base = StringFormat("WiseTrader_%s_%d", symbol, (int)magic);
      m_cmd_file    = base + ".cmd";
      m_ack_file    = base + ".ack";
      m_status_file = base + ".status.json";
     }

   bool              Paused(void) const { return m_paused; }

   // Poll for a command. Returns the command executed ("" if none).
   // flatten_request / clear_lock_request are signaled to the caller,
   // which owns the executor and risk manager.
   string            Poll(bool &flatten_request, bool &clear_lock_request)
     {
      flatten_request = false;
      clear_lock_request = false;
      if(!FileIsExist(m_cmd_file, FILE_COMMON))
         return "";
      int h = FileOpen(m_cmd_file, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h == INVALID_HANDLE)
         return "";
      string cmd = FileReadString(h);
      FileClose(h);
      FileDelete(m_cmd_file, FILE_COMMON);
      StringTrimLeft(cmd);
      StringTrimRight(cmd);
      StringToUpper(cmd);

      if(cmd == "PAUSE")            { m_paused = true;  WriteAck(cmd, "ok"); }
      else if(cmd == "RESUME")      { m_paused = false; WriteAck(cmd, "ok"); }
      else if(cmd == "FLATTEN")     { flatten_request = true;    WriteAck(cmd, "ok"); }
      else if(cmd == "CLEAR_LOCK")  { clear_lock_request = true; WriteAck(cmd, "ok"); }
      else if(cmd != "")            { WriteAck(cmd, "unknown command"); cmd = ""; }
      return cmd;
     }

   // Drop a JSON state snapshot for the dashboard (timer path only).
   void              WriteStatus(const string symbol, const ENUM_TIMEFRAMES tf,
                                 const int lock, const int setup_state,
                                 const int trend, const double equity,
                                 const double day_eq, const double peak_eq,
                                 const int streak, const int positions,
                                 const double vwap, const double poc,
                                 const double wave, const bool analytics_ok)
     {
      int h = FileOpen(m_status_file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h == INVALID_HANDLE) return;
      FileWriteString(h, StringFormat(
         "{\"time\":\"%s\",\"symbol\":\"%s\",\"tf\":\"%s\",\"paused\":%s," +
         "\"lock\":%d,\"setup_state\":%d,\"trend\":%d,\"equity\":%.2f," +
         "\"day_eq\":%.2f,\"peak_eq\":%.2f,\"streak\":%d,\"positions\":%d," +
         "\"vwap\":%.2f,\"poc\":%.2f,\"cycle\":%.3f,\"analytics_ok\":%s}\n",
         TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), symbol, EnumToString(tf),
         m_paused ? "true" : "false",
         lock, setup_state, trend, equity, day_eq, peak_eq, streak, positions,
         vwap, poc, wave, analytics_ok ? "true" : "false"));
      FileClose(h);
     }
  };

#endif // WT_COMMANDS_MQH
