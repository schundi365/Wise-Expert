//+------------------------------------------------------------------+
//| WiseTrader - Config.mqh                                          |
//| Shared enums, structs and settings for all modules.              |
//+------------------------------------------------------------------+
#ifndef WT_CONFIG_MQH
#define WT_CONFIG_MQH

//--- signal direction
enum ENUM_WT_DIR
  {
   WT_DIR_NONE = 0,
   WT_DIR_LONG = 1,
   WT_DIR_SHORT= -1
  };

//--- signal source
enum ENUM_WT_SIGNAL
  {
   WT_SIG_NONE = 0,
   WT_SIG_BOS,          // structure continuation break
   WT_SIG_CHOCH,        // change of character (reversal break)
   WT_SIG_QM            // Quasimodo reversal
  };

//--- setup lifecycle (Discipline layer FSM)
enum ENUM_WT_SETUP_STATE
  {
   WT_NO_SETUP = 0,
   WT_SETUP_FORMING,
   WT_SETUP_CONFIRMED,
   WT_SETUP_ACTIVE,
   WT_SETUP_EXPIRED
  };

//--- global lock reasons
enum ENUM_WT_LOCK
  {
   WT_LOCK_NONE = 0,
   WT_LOCK_DAILY_LOSS,      // daily loss limit hit  (clears next server day)
   WT_LOCK_STREAK,          // max consecutive losses (clears next server day)
   WT_LOCK_TOTAL_DD         // total drawdown hard stop (manual clear only)
  };

//--- trailing mode
enum ENUM_WT_TRAIL
  {
   WT_TRAIL_ATR = 0,        // volatility trailing k*ATR
   WT_TRAIL_STRUCTURE       // behind last confirmed swing
  };

//--- break entry mode (v2.1): how structure breaks become entries
enum ENUM_WT_ENTRY_MODE
  {
   WT_ENTRY_M15_CLOSE = 0,  // decision-TF close confirmation (slowest, most filtered)
   WT_ENTRY_M1_CLOSE,       // M1 close beyond the level (~1 min latency, keeps confirmation)
   WT_ENTRY_STOP_ORDER      // resting stop at the level (instant fill, NO close confirmation)
  };

//--- a fully described trade setup emitted by the signal engine
struct SSetup
  {
   ENUM_WT_SIGNAL    signal;
   ENUM_WT_DIR       dir;
   double            entry;         // reference entry price (signal-bar close)
   double            invalidation;  // hard stop anchor
   double            target;        // primary target (0 = use RR fallback)
   double            score;         // confluence score 0..1
   datetime          bar_time;      // decision bar time of the signal
   string            evidence;      // human-readable scoring evidence
   double            level;         // broken structure level (0 = n/a)
   double            retest_px;     // pullback trigger price (0 = n/a)
   bool              pending_retest;// true = wait for pullback before entry
  };

//--- runtime settings shared by modules (filled from EA inputs)
struct SSettings
  {
   string            symbol;
   ENUM_TIMEFRAMES   tf;            // decision timeframe
   long              magic;
   //--- risk
   double            risk_per_trade_pct;   // % equity risked per trade
   double            max_daily_loss_pct;   // daily loss cutoff (closed+floating)
   double            max_total_dd_pct;     // hard stop from peak equity
   int               max_consec_losses;    // per day
   int               max_positions;        // per symbol+magic
   double            min_rr;               // minimum reward:risk at entry
   //--- stops / management
   double            atr_stop_floor_mult;  // min stop distance = k*ATR
   double            breakeven_r;          // move to BE at this R multiple
   double            trail_atr_mult;       // ATR trailing distance
   ENUM_WT_TRAIL     trail_mode;
   //--- adaptive risk & targets
   double            gap_buffer_atr;       // sizing gap buffer floor, ATR mult
   int               gap_lookback;         // bars scanned for worst open gap
   double            vol_full_ratio;       // ATR14/ATR100 <= this -> full risk
   double            vol_min_ratio;        // ATR14/ATR100 >= this -> floor risk
   double            vol_risk_floor;       // risk fraction at/above vol_min_ratio (0..1)
   double            tp_cap_atr;           // max TP distance, ATR mult (0 = off)
   double            partial_pct;          // % volume closed at BE trigger (0 = off)
   //--- signals
   double            min_score;            // confluence threshold 0..1
   int               setup_max_age_bars;   // freshness window
   int               session_start_hour;   // server time trade window
   int               session_end_hour;
   //--- signal quality (v1.8)
   double            max_chase_atr;        // max entry distance beyond level, ATR mult
   double            retest_tol_atr;       // retest touch tolerance, ATR mult
   int               retest_max_bars;      // bars to wait for the pullback
   double            min_adx;              // min ADX for BOS/CHoCH entries (0 = off)
   bool              news_enabled;         // block entries near high-impact news
   int               news_block_min;       // blackout window, +/- minutes
   //--- volume & outliers (v2.0)
   double            min_relvol;           // min relative volume for BOS/CHoCH (0 = off)
   int               relvol_days;          // sessions in the time-of-day baseline
   double            outlier_z;            // modified Z outlier threshold (0 = off)
   //--- early entry (v2.1)
   ENUM_WT_ENTRY_MODE entry_mode;          // how breaks become entries
   bool              retest_limit;         // resting limit order at the retest price
   double            stop_buffer_atr;      // stop-order offset beyond the level, ATR mult
   //--- stop management (v2.2)
   double            be_atr_trigger;       // BE also arms at k*ATR profit (0 = off)
   double            lock_start_pct;       // lock profit once this % of TP dist covered (0 = off)
   double            lock_pct;             // % of open profit locked by the stop
   //--- engine
   ulong             tick_budget_us;       // scheduler budget per tick event
   ulong             timer_budget_us;      // scheduler budget per timer event
  };

// Human-readable lock name
string LockName(const ENUM_WT_LOCK l)
  {
   switch(l)
     {
      case WT_LOCK_DAILY_LOSS: return "DAILY_LOSS";
      case WT_LOCK_STREAK:     return "LOSS_STREAK";
      case WT_LOCK_TOTAL_DD:   return "TOTAL_DD";
     }
   return "NONE";
  }

// Convenience: clear a setup
void SetupReset(SSetup &s)
  {
   s.signal = WT_SIG_NONE; s.dir = WT_DIR_NONE;
   s.entry = 0; s.invalidation = 0; s.target = 0;
   s.score = 0; s.bar_time = 0; s.evidence = "";
   s.level = 0; s.retest_px = 0; s.pending_retest = false;
  }

#endif // WT_CONFIG_MQH
