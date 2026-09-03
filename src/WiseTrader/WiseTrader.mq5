//+------------------------------------------------------------------+
//| WiseTrader.mq5 - Autonomous MT5 Trading Bot (Phase 1 MVP)        |
//| Built from the Wise Trader Build Specification v1.0.             |
//|                                                                  |
//| Non-blocking architecture:                                       |
//|  - OnTick does trade management only (microseconds) plus a       |
//|    time-budgeted slice of pending analytics.                     |
//|  - Heavy features (VWAP, volume profile, Ehlers) update          |
//|    incrementally through a cooperative scheduler; leftovers      |
//|    finish on the 1-second timer, never stalling ticks.           |
//|  - Journal writes are buffered in memory and flushed on the      |
//|    timer, never on the tick path.                                |
//|  - Risk counters live in terminal global variables and survive   |
//|    restarts; trade-management state is inferred from broker-side |
//|    stops, so recovery is automatic.                              |
//+------------------------------------------------------------------+
#property copyright "Wise Trader project"
#property version   "2.51"
#property description "Rule-based autonomous bot: market structure + Quasimodo signals, VWAP/volume-profile/cycle confluence, disciplined authorization, hard risk limits."

// Single source of truth for the version string used in logs/journals.
// Keep this equal to #property version above - #property values are not
// readable at runtime, so this is duplicated by necessity, not choice.
#define WT_VERSION "2.51"

#include "src/Config.mqh"
#include "src/Journal.mqh"
#include "src/Scheduler.mqh"
#include "src/Vwap.mqh"
#include "src/VolumeProfile.mqh"
#include "src/Ehlers.mqh"
#include "src/Structure.mqh"
#include "src/Quasimodo.mqh"
#include "src/SignalEngine.mqh"
#include "src/Discipline.mqh"
#include "src/Risk.mqh"
#include "src/Execution.mqh"
#include "src/Commands.mqh"
#include "src/NewsFilter.mqh"
#include "src/RelVolume.mqh"
#include "src/Outliers.mqh"
#include "src/SymbolProfile.mqh"

//--- inputs ---------------------------------------------------------
input group "General"
input string   InpSymbol           = "";         // Symbol override ("" = chart symbol)
input long     InpMagic            = 20260707;   // Magic number
input ENUM_TIMEFRAMES InpTF        = PERIOD_M15; // Decision timeframe
input bool     InpUseSymbolOverrides = true;     // Apply per-symbol tuned params (v2.43); false = pure EA-input defaults on every symbol, for ablation testing

input group "Risk (Moderate profile)"
input double   InpRiskPerTrade     = 1.0;        // Risk per trade, % equity
input double   InpMaxDailyLoss     = 3.0;        // Max daily loss, %
input double   InpMaxTotalDD       = 10.0;       // Max total drawdown, % (flatten + lock)
input int      InpMaxConsecLosses  = 3;          // Max consecutive losses per day
input int      InpMaxPositions     = 1;          // Max open positions (symbol+magic)
input double   InpMinRR            = 1.5;        // Minimum reward:risk

input group "Stops & management"
input double   InpAtrStopFloor     = 1.5;        // Min stop distance, ATR mult
input double   InpBreakevenR       = 1.0;        // Breakeven trigger, R multiple
input double   InpTrailAtrMult     = 2.0;        // ATR trailing distance
input ENUM_WT_TRAIL InpTrailMode   = WT_TRAIL_ATR; // Trailing mode
input double   InpFallbackRR       = 2.0;        // TP = RR fallback when no pattern target
input double   InpBeAtrTrigger     = 0;          // BE also arms at k*ATR profit (0 = off, v2.2; OFF by default - v2.42 D1 regression: crushed avg win $38->$16)
input double   InpLockStartPct     = 0;          // Lock profit at this % of TP distance (0 = off, v2.2; OFF by default - v2.42, same evidence as above)
input double   InpLockPct          = 50.0;       // % of open profit locked by the stop (v2.2)

input group "Adaptive risk & targets"
input double   InpTpCapAtr         = 3.0;        // Max TP distance, ATR mult (0 = off)
input double   InpPartialPct       = 50.0;       // Partial close % at BE trigger (0 = off)
input double   InpGapBufferAtr     = 0.5;        // Sizing gap buffer floor, ATR mult
input int      InpGapLookback      = 20;         // Gap lookback, bars
input double   InpVolFullRatio     = 1.0;        // ATR14/ATR100 <= this: full risk
input double   InpVolMinRatio      = 2.0;        // ATR14/ATR100 >= this: floor risk
input double   InpVolRiskFloor     = 1.0;        // Risk fraction at floor (0..1); = InpVolFullRatio -> scaling flat/off by default (v2.42 B2 regression: PF 1.29->1.48 with it off)

input group "Signals"
input double   InpMinScore         = 0.55;       // Confluence threshold 0..1 (v1.8: was 0.45)
input int      InpSetupMaxAge      = 3;          // Setup freshness, bars
input int      InpSwingWing        = 3;          // Swing confirmation bars each side
input double   InpQmZoneAtr        = 0.5;        // QM shoulder zone, ATR mult
input double   InpProfileBin       = 0.20;       // Volume profile bin size (price units)
input int      InpSessionStart     = 12;         // Trade window start hour (server) (v1.9: was 7)
input int      InpSessionEnd       = 20;         // Trade window end hour (server)

input group "Signal quality (v1.8)"
input double   InpMaxChaseAtr      = 0.75;       // Max entry beyond level, ATR mult (0 = off)
input double   InpRetestTolAtr     = 0.25;       // Retest touch tolerance, ATR mult
input int      InpRetestMaxBars    = 8;          // Bars to wait for the pullback
input double   InpMinAdx           = 0;          // Min ADX for BOS/CHoCH (0 = off; OFF by default - v2.42 B4 regression: PF 1.29->1.48 with it off)
input bool     InpNewsFilter       = true;       // Block entries near high-impact news
input int      InpNewsBlockMin     = 30;         // News blackout, +/- minutes

input group "Early entry (v2.1)"
input ENUM_WT_ENTRY_MODE InpBreakEntryMode = WT_ENTRY_M15_CLOSE; // Break entry: M15 close | M1 close | stop order
input bool     InpRetestLimit      = true;       // Resting limit order at retest price (vs bar-close touch)
input double   InpStopBufferAtr    = 0.05;       // Stop-order offset beyond level, ATR mult

input group "Volume & outliers (v2.0)"
input double   InpMinRelVol        = 1.0;        // Min relative volume for BOS/CHoCH (0 = off)
input int      InpRelVolDays       = 20;         // Sessions for time-of-day volume baseline
input double   InpOutlierZ         = 3.5;        // Outlier bar threshold, modified Z (0 = off)

input group "Momentum confluence (v2.44, F52)"
input bool     InpUseMomentum      = false;      // Score bonus for RSI agreeing with trade direction (OFF by default - REJECTED 2026-07-28 M15 campaign, PF 1.44->1.19; kept as toggle for reference)
input int      InpMomentumPeriod   = 14;         // RSI period - sustained pressure over 14+ bars, not last 3-4
input double   InpMomentumWeight   = 0.15;       // Score add-on when RSI agrees with trade direction
input double   InpMomentumLongTh   = 55.0;       // RSI must be above this for long alignment
input double   InpMomentumShortTh  = 45.0;       // RSI must be below this for short alignment

input group "Trend-slope confluence (v2.45, F53)"
input bool     InpUseRegression    = false;      // Score bonus for OLS slope agreeing with trade direction (OFF by default - REJECTED 2026-07-28, marginal net gain offset by worse Sharpe; kept as toggle for reference)
input int      InpRegressionLookback = 30;       // Bars in the linear-regression window (catches grinding trends structure misses)
input double   InpRegressionWeight = 0.15;       // Score add-on when slope agrees and fit is strong
input double   InpRegressionMinR2  = 0.30;       // Min R^2 for the slope to count as a real trend, not noise

input group "Ehlers cycle weight (v2.46, F54)"
input double   InpCycleTurnWeight  = 0.20;       // Score add-on when Ehlers cycle turns WITH the trade (was hardcoded 0.20; REJECTED 2026-07-28, zero effect at 0.30/0.40 - kept for reference)

input group "Volatility-regime confluence (v2.47, F55)"
input bool     InpUseVolRegime     = false;      // Score bonus for ATR14/ATR100 expansion (directionless; OFF by default - candidate, promising in-sample (net +15%, PF 1.44->1.52), pending model 4 + OOS)
input double   InpVolRegimeMinRatio = 1.3;       // ATR14/ATR100 must exceed this to count as expansion (vs squeeze/normal)
input double   InpVolRegimeWeight  = 0.15;       // Score add-on when expanding

input group "Persistence confluence (v2.48, F56)"
input bool     InpUsePersistence   = false;      // Score bonus for variance-ratio persistence (directionless; OFF by default - candidate, not yet validated)
input int      InpPersistenceLookback = 60;      // Bars in the 1-period return series
input int      InpPersistenceQ     = 5;          // Block size for the q-period variance (Lo-MacKinlay style)
input double   InpPersistenceMinVr = 1.15;       // Min variance ratio to count as a persistent (trending) regime
input double   InpPersistenceWeight = 0.15;      // Score add-on when persistent

input group "Multi-timeframe agreement (v2.49, F57)"
input bool     InpUseMtf           = false;      // Score bonus when a higher TF agrees with trade direction (OFF by default - candidate, not yet validated; handle only created when true, avoids pulling HTF history otherwise)
input ENUM_TIMEFRAMES InpMtfTf     = PERIOD_H1;  // Higher timeframe to check agreement against
input int      InpMtfMaPeriod      = 50;         // EMA period on that timeframe (close vs EMA = HTF bias)
input double   InpMtfWeight        = 0.15;       // Score add-on when HTF agrees

input group "Protective flatten (v2.4)"
input int      InpNewsFlattenMin   = 0;          // Close positions N min before high-impact news (0 = off; live only)
input int      InpFridayFlattenHour= 22;         // Friday flatten hour, server time (0 = off; e.g. 22) - ON by default (v2.42 D4 regression: weekend gap protection net positive)

input group "Engine"
input ulong    InpTickBudgetUs     = 3000;       // Analytics budget per tick, microseconds
input ulong    InpTimerBudgetUs    = 50000;      // Analytics budget per timer event
input bool     InpResetRiskState   = false;      // Reset persisted risk state on init (after account change / manual lock clear)
input string   InpTestTag          = "";         // Test-case name: tags the journal file and init line (set per .set config)

//--- module instances ----------------------------------------------
SSettings         g_cfg;
CJournal          g_journal;
CScheduler        g_sched;
CSessionVwap      g_vwap;
CSessionProfile   g_profile;
CEhlers           g_ehlers;
CMarketStructure  g_structure;
CQuasimodo        g_qm;
CSignalEngine     g_engine;
CDiscipline       g_discipline;
CRiskManager      g_risk;
CExecutor         g_exec;
CTradeManager     g_manager;
CCommandBridge    g_bridge;
CNewsFilter       g_news;
CRelVolume        g_relvol;
COutlierMask      g_outliers;
double            g_atr = 0;             // outlier-clean ATR for the current bar

datetime          g_last_bar = 0;        // decision-TF new-bar gate
datetime          g_last_m1  = 0;        // M1 new-bar gate (early entry mode)
datetime          g_session_day = 0;     // current session anchor (server day)
datetime          g_last_comment = 0;    // dashboard throttle
bool              g_flattened = false;   // total-DD flatten latch
string            g_last_veto = "";      // last rejection reason (dashboard)

//+------------------------------------------------------------------+
datetime DayStart(const datetime t) { return (datetime)(t - t % 86400); }

//+------------------------------------------------------------------+
int OnInit(void)
  {
   //--- settings
   g_cfg.symbol              = (InpSymbol == "") ? _Symbol : InpSymbol;
   if(!SymbolSelect(g_cfg.symbol, true))
     {
      Print("WiseTrader: symbol '", g_cfg.symbol, "' not found in Market Watch");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_cfg.tf                  = InpTF;
   g_cfg.magic               = InpMagic;
   g_cfg.risk_per_trade_pct  = InpRiskPerTrade;
   g_cfg.max_daily_loss_pct  = InpMaxDailyLoss;
   g_cfg.max_total_dd_pct    = InpMaxTotalDD;
   g_cfg.max_consec_losses   = InpMaxConsecLosses;
   g_cfg.max_positions       = InpMaxPositions;
   g_cfg.min_rr              = InpMinRR;
   g_cfg.atr_stop_floor_mult = InpAtrStopFloor;
   g_cfg.breakeven_r         = InpBreakevenR;
   g_cfg.trail_atr_mult      = InpTrailAtrMult;
   g_cfg.trail_mode          = InpTrailMode;
   g_cfg.tp_cap_atr          = InpTpCapAtr;
   g_cfg.partial_pct         = InpPartialPct;
   g_cfg.gap_buffer_atr      = InpGapBufferAtr;
   g_cfg.gap_lookback        = InpGapLookback;
   g_cfg.vol_full_ratio      = InpVolFullRatio;
   g_cfg.vol_min_ratio       = InpVolMinRatio;
   g_cfg.vol_risk_floor      = InpVolRiskFloor;
   g_cfg.min_score           = InpMinScore;
   g_cfg.setup_max_age_bars  = InpSetupMaxAge;
   g_cfg.session_start_hour  = InpSessionStart;
   g_cfg.session_end_hour    = InpSessionEnd;
   g_cfg.max_chase_atr       = InpMaxChaseAtr;
   g_cfg.retest_tol_atr      = InpRetestTolAtr;
   g_cfg.retest_max_bars     = InpRetestMaxBars;
   g_cfg.min_adx             = InpMinAdx;
   g_cfg.news_enabled        = InpNewsFilter;
   g_cfg.news_block_min      = InpNewsBlockMin;
   g_cfg.min_relvol          = InpMinRelVol;
   g_cfg.relvol_days         = InpRelVolDays;
   g_cfg.outlier_z           = InpOutlierZ;
   g_cfg.entry_mode          = InpBreakEntryMode;
   g_cfg.retest_limit        = InpRetestLimit;
   g_cfg.stop_buffer_atr     = InpStopBufferAtr;
   g_cfg.use_momentum        = InpUseMomentum;
   g_cfg.momentum_period     = InpMomentumPeriod;
   g_cfg.momentum_weight     = InpMomentumWeight;
   g_cfg.momentum_long_th    = InpMomentumLongTh;
   g_cfg.momentum_short_th   = InpMomentumShortTh;
   g_cfg.use_regression      = InpUseRegression;
   g_cfg.regression_lookback = InpRegressionLookback;
   g_cfg.regression_weight   = InpRegressionWeight;
   g_cfg.regression_min_r2   = InpRegressionMinR2;
   g_cfg.cycle_turn_weight   = InpCycleTurnWeight;
   g_cfg.use_vol_regime      = InpUseVolRegime;
   g_cfg.vol_regime_min_ratio= InpVolRegimeMinRatio;
   g_cfg.vol_regime_weight   = InpVolRegimeWeight;
   g_cfg.use_persistence       = InpUsePersistence;
   g_cfg.persistence_lookback  = InpPersistenceLookback;
   g_cfg.persistence_q         = InpPersistenceQ;
   g_cfg.persistence_min_vr    = InpPersistenceMinVr;
   g_cfg.persistence_weight    = InpPersistenceWeight;
   g_cfg.use_mtf             = InpUseMtf;
   g_cfg.mtf_tf              = InpMtfTf;
   g_cfg.mtf_ma_period       = InpMtfMaPeriod;
   g_cfg.mtf_weight          = InpMtfWeight;
   g_cfg.be_atr_trigger      = InpBeAtrTrigger;
   g_cfg.lock_start_pct      = InpLockStartPct;
   g_cfg.lock_pct            = InpLockPct;
   g_cfg.tick_budget_us      = InpTickBudgetUs;
   g_cfg.timer_budget_us     = InpTimerBudgetUs;

   //--- per-symbol overrides (v2.43): one compiled EA, tuned params per
   //--- symbol instead of manual .set swaps. See SymbolProfile.mqh for the
   //--- evidence behind each row; symbol_override_note is journaled below
   //--- so every run is traceable to which override (if any) fired.
   double profile_bin = InpProfileBin;
   string symbol_override_note = "disabled (InpUseSymbolOverrides=false)";
   if(InpUseSymbolOverrides)
      symbol_override_note = ApplySymbolOverrides(g_cfg.symbol, g_cfg, profile_bin);

   //--- modules
   g_journal.Init(g_cfg.symbol, g_cfg.magic, InpTestTag);
   g_vwap.Setup(g_cfg.symbol, 300);
   g_profile.Setup(g_cfg.symbol, 300);
   g_profile.SetBinSize(profile_bin);
   g_ehlers.Init(g_cfg.symbol, g_cfg.tf);
   g_structure.Init(g_cfg.symbol, g_cfg.tf, InpSwingWing);
   g_qm.Init(g_cfg.symbol, g_cfg.tf, InpQmZoneAtr);
   g_engine.Init(g_cfg);
   g_discipline.Init(g_cfg);
   g_risk.Init(g_cfg, InpResetRiskState);
   g_exec.Init(g_cfg, GetPointer(g_journal));
   g_manager.Init(g_cfg, GetPointer(g_exec), GetPointer(g_journal));
   g_bridge.Init(g_cfg.symbol, g_cfg.magic);
   g_news.Init(g_cfg);
   g_relvol.Init(g_cfg.symbol, g_cfg.tf, InpRelVolDays);
   g_outliers.Init(g_cfg.symbol, g_cfg.tf, 100);

   //--- register incremental jobs (order = execution priority)
   g_sched.Register(GetPointer(g_vwap));
   g_sched.Register(GetPointer(g_profile));
   g_sched.Register(GetPointer(g_ehlers));

   //--- start today's session and queue the initial build
   g_session_day = DayStart(TimeCurrent());
   g_vwap.Reset(g_session_day);
   g_profile.Reset(g_session_day);
   g_sched.MarkAllPending();

   EventSetTimer(1);
   g_journal.Log("RECOVER", StringFormat("init: v%s test_case=%s lock=%d streak=%d positions=%d equity=%.2f day_eq=%.2f peak_eq=%.2f",
                 WT_VERSION, InpTestTag == "" ? "(untagged)" : InpTestTag,
                 (int)g_risk.Lock(), g_risk.LossStreak(), g_risk.OpenPositions(),
                 AccountInfoDouble(ACCOUNT_EQUITY), g_risk.DayStartEquity(), g_risk.PeakEquity()));
   g_journal.Log("RECOVER", StringFormat("symbol overrides [%s]: %s", g_cfg.symbol, symbol_override_note));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_journal.Flush();
   Comment("");
  }

//+------------------------------------------------------------------+
//| Tick path - kept minimal. Order of operations:                   |
//|  1) equity guards (cheap)  2) manage positions  3) new-bar       |
//|  pipeline  4) budgeted analytics slice                           |
//+------------------------------------------------------------------+
void OnTick(void)
  {
   //--- 1) equity guards
   const ENUM_WT_LOCK guard = g_risk.CheckEquityGuards();
   if(guard == WT_LOCK_TOTAL_DD)
     {
      if(!g_flattened)
        {
         g_exec.CloseAll("total drawdown hard stop");
         g_journal.Log("RISK", "TOTAL DD LOCK - manual clear of global variables required to resume");
         SendNotification("WiseTrader: TOTAL DD hard stop - account flattened and locked");
         g_flattened = true;
        }
      return;
     }

   //--- 2) manage open positions (always, even when locked)
   g_manager.Manage(g_structure);

   //--- 3) new decision bar?
   const datetime bar = iTime(g_cfg.symbol, g_cfg.tf, 0);
   if(bar != g_last_bar)
     {
      g_last_bar = bar;
      OnNewBar();
     }

   //--- 3b) early entry: M1-close break confirmation (~1 min latency)
   if(g_cfg.entry_mode == WT_ENTRY_M1_CLOSE)
     {
      const datetime m1 = iTime(g_cfg.symbol, PERIOD_M1, 0);
      if(m1 != g_last_m1)
        {
         g_last_m1 = m1;
         OnNewM1();
        }
     }

   //--- 4) analytics slice under tick budget (finishes on timer if needed)
   g_sched.RunPending(g_cfg.tick_budget_us);
  }

//+------------------------------------------------------------------+
void OnNewBar(void)
  {
   //--- session rollover
   const datetime today = DayStart(TimeCurrent());
   if(today != g_session_day)
     {
      g_session_day = today;
      g_vwap.Reset(today);
      g_profile.Reset(today);
     }

   //--- queue incremental feature updates
   g_sched.MarkAllPending();

   //--- structure update is cheap; run inline
   g_structure.Update();

   //--- F16 outlier mask: a news/flash candle is not a signal. The bar is
   //--- ignored entirely: no FSM aging, no retest confirmation (a spike
   //--- touch is not a pullback), no signal generation on fake BOS levels.
   if(g_outliers.IsOutlier(1, InpOutlierZ))
     {
      g_journal.Log("VETO", StringFormat("outlier bar masked, z=%.1f", g_outliers.ZScore(1)));
      g_last_veto = "outlier bar";
      return;
     }

   //--- advance the discipline FSM (close/high/low of the closed bar:
   //--- FORMING retest setups confirm on a touch of the broken level)
   g_discipline.OnNewBar(iClose(g_cfg.symbol, g_cfg.tf, 1),
                         iHigh(g_cfg.symbol, g_cfg.tf, 1),
                         iLow(g_cfg.symbol, g_cfg.tf, 1));

   //--- pending-order lifecycle: a resting order must never outlive its
   //--- setup (also cleans up orphans after a terminal restart)
   const ENUM_WT_SETUP_STATE st = g_discipline.State();
   if(g_cfg.entry_mode != WT_ENTRY_STOP_ORDER &&
      (st == WT_SETUP_EXPIRED || st == WT_NO_SETUP) &&
      g_exec.PendingCount() > 0)
      g_exec.CancelPending("setup expired/invalidated");

   //--- try to finish analytics within the tick budget before deciding
   g_sched.RunPending(g_cfg.tick_budget_us);

   //--- outlier-clean ATR for validation/targets (falls back to raw iATR);
   //--- one NFP candle must not double the stop floor for the next 14 bars
   const double atr_raw = g_manager.AtrValue();
   g_atr = atr_raw;
   const double atr_clean = g_outliers.CleanAtr(14, InpOutlierZ);
   if(atr_clean > 0)
      g_atr = atr_clean;

   //--- signal pipeline (features not ready = scoring degrades gracefully)
   const double atr = g_atr;
   SSetup setup;
   string reject;
   if(g_engine.Poll(g_structure, g_qm, g_vwap, g_profile, g_ehlers, atr,
                    g_relvol.Ratio(), setup, reject))
     {
      g_discipline.Register(setup);
      g_journal.Log("DECISION", StringFormat("setup %s score=%.2f entry=%.2f inv=%.2f tgt=%.2f%s [%s]",
                    setup.dir == WT_DIR_LONG ? "LONG" : "SHORT",
                    setup.score, setup.entry, setup.invalidation, setup.target,
                    setup.pending_retest ? " AWAIT-RETEST" : "", setup.evidence));
      if(!setup.pending_retest)
         TryExecute();
      else if(g_cfg.retest_limit)
         PlaceRetestLimit(setup);
     }
   else
     {
      if(reject != "")
        {
         g_journal.Log("VETO", "signal rejected: " + reject);
         g_last_veto = reject;
        }
      //--- execute a retest setup that just confirmed, or retry a
      //--- still-valid setup whose order failed transiently
      if(g_discipline.State() == WT_SETUP_CONFIRMED ||
         g_discipline.State() == WT_SETUP_ACTIVE)
         TryExecute();
     }

   //--- early entry: resting stop orders at live with-trend levels
   if(g_cfg.entry_mode == WT_ENTRY_STOP_ORDER)
      MaintainStopOrders();
  }

//+------------------------------------------------------------------+
//| TP from a given entry price: RR fallback + ATR cap (clean ATR).   |
//+------------------------------------------------------------------+
double ComputeTp(const ENUM_WT_DIR dir, const double price, const double sl,
                 const double target)
  {
   const double stop_dist = MathAbs(price - sl);
   double tp = target;
   if(tp == 0)
      tp = (dir == WT_DIR_LONG) ? price + InpFallbackRR * stop_dist
                                : price - InpFallbackRR * stop_dist;
   const double atr = (g_atr > 0) ? g_atr : g_manager.AtrValue();
   if(InpTpCapAtr > 0 && atr > 0 && stop_dist > 0)
     {
      const double tp_dist = MathAbs(tp - price);
      const double capped  = MathMax(MathMin(tp_dist, InpTpCapAtr * atr),
                                     g_cfg.min_rr * stop_dist);
      if(capped < tp_dist)
        {
         tp = (dir == WT_DIR_LONG) ? price + capped : price - capped;
         g_journal.Log("DECISION", StringFormat("TP capped %.5f -> %.5f (%.1fxATR)",
                       tp_dist, capped, InpTpCapAtr));
        }
     }
   return tp;
  }

//+------------------------------------------------------------------+
//| Early entry: resting limit at the retest price (v2.1).            |
//| The FSM keeps tracking the setup; if the limit can't be placed    |
//| the bar-close touch flow still works as fallback. On fill,        |
//| OnTradeTransaction consumes the setup.                            |
//+------------------------------------------------------------------+
void PlaceRetestLimit(const SSetup &s)
  {
   if(g_bridge.Paused() || g_risk.Locked())
      return;
   if(!g_discipline.InSession())
      return;
   string news;
   if(g_news.Blocked(news))
     { g_journal.Log("VETO", "limit not placed: " + news); return; }
   if(g_exec.PendingCount() > 0)
      g_exec.CancelPending("superseded by new setup");

   double lots = 0;
   string veto;
   if(!g_risk.CanOpen(s.dir, s.retest_px, s.invalidation, lots, veto))
     {
      g_journal.Log("VETO", "retest limit risk veto: " + veto);
      return;
     }
   const double tp = ComputeTp(s.dir, s.retest_px, s.invalidation, s.target);
   const string comment = StringFormat("WT|%s|%.2f|RL",
                          s.signal == WT_SIG_QM ? "QM" : (s.signal == WT_SIG_CHOCH ? "CHOCH" : "BOS"),
                          s.score);
   if(g_exec.PlaceLimit(s.dir, lots, s.retest_px, s.invalidation, tp, comment))
      g_journal.Log("RISK", "sizing: " + g_risk.SizingNote());
  }

//+------------------------------------------------------------------+
//| Early entry: M1-close break confirmation (v2.1). Runs once per    |
//| new M1 bar; checks the M15 structure levels against the M1 close  |
//| and enters ~1 minute after the break instead of up to 15.         |
//+------------------------------------------------------------------+
void OnNewM1(void)
  {
   //--- respect the M15 outlier mask (stats cached per M15 bar)
   if(g_outliers.IsOutlier(1, InpOutlierZ))
      return;
   if(!g_structure.BreakCheck(iClose(g_cfg.symbol, PERIOD_M1, 1),
                              iTime(g_cfg.symbol, PERIOD_M1, 1)))
      return;

   SStructureEvent e;
   g_structure.GetEvent(e);
   g_structure.ClearEvent();      // consumed here; M15 Poll must not re-see it

   SSetup s;
   string reject;
   const double atr = (g_atr > 0) ? g_atr : g_manager.AtrValue();
   if(!g_engine.EvaluateBreak(g_structure, g_vwap, g_profile, g_ehlers,
                              atr, g_relvol.Ratio(),
                              iClose(g_cfg.symbol, PERIOD_M1, 1), e, s, reject))
     {
      g_journal.Log("VETO", "M1 break rejected: " + reject);
      g_last_veto = reject;
      return;
     }
   g_discipline.Register(s);
   g_journal.Log("DECISION", StringFormat("M1 setup %s score=%.2f entry=%.2f inv=%.2f%s [%s]",
                 s.dir == WT_DIR_LONG ? "LONG" : "SHORT", s.score, s.entry,
                 s.invalidation, s.pending_retest ? " AWAIT-RETEST" : "", s.evidence));
   if(!s.pending_retest)
      TryExecute();
   else if(g_cfg.retest_limit)
      PlaceRetestLimit(s);
  }

//+------------------------------------------------------------------+
//| Early entry: resting stop order at the live with-trend level      |
//| (v2.1). One pending max; refreshed every M15 bar. CHoCH (counter- |
//| trend) is NOT traded via stops - it keeps close confirmation.     |
//+------------------------------------------------------------------+
void MaintainStopOrders(void)
  {
   //--- refresh policy: cancel and re-place from current state
   if(g_exec.PendingCount() > 0)
      g_exec.CancelPending("stop-order refresh");
   if(g_bridge.Paused() || g_risk.Locked() || g_risk.OpenPositions() > 0)
      return;
   if(!g_discipline.InSession())
      return;
   string news;
   if(g_news.Blocked(news))
      return;
   if(g_outliers.IsOutlier(1, InpOutlierZ))
      return;

   const double atr = (g_atr > 0) ? g_atr : g_manager.AtrValue();
   if(atr <= 0)
      return;

   //--- with-trend candidate only: long stop above the live high in an
   //--- up/neutral trend, short stop below the live low in a down/neutral
   const ENUM_WT_DIR trend = g_structure.Trend();
   ENUM_WT_DIR dir = WT_DIR_NONE;
   double level = 0;
   if(g_structure.HighLive() && trend != WT_DIR_SHORT)
     { dir = WT_DIR_LONG;  level = g_structure.LastHigh(); }
   else if(g_structure.LowLive() && trend != WT_DIR_LONG)
     { dir = WT_DIR_SHORT; level = g_structure.LastLow(); }
   if(dir == WT_DIR_NONE || level <= 0)
      return;

   const double entry = (dir == WT_DIR_LONG)
                        ? level + g_cfg.stop_buffer_atr * atr
                        : level - g_cfg.stop_buffer_atr * atr;
   //--- price must still be on the near side of the level
   const double cur = (dir == WT_DIR_LONG)
                      ? SymbolInfoDouble(g_cfg.symbol, SYMBOL_ASK)
                      : SymbolInfoDouble(g_cfg.symbol, SYMBOL_BID);
   if((dir == WT_DIR_LONG && cur >= entry) || (dir == WT_DIR_SHORT && cur <= entry))
      return;

   //--- pre-score the hypothetical break at the level
   SStructureEvent e;
   e.type = WT_SIG_BOS; e.dir = dir; e.level = level;
   e.bar_time = iTime(g_cfg.symbol, g_cfg.tf, 0);
   SSetup s;
   string reject;
   if(!g_engine.EvaluateBreak(g_structure, g_vwap, g_profile, g_ehlers,
                              atr, g_relvol.Ratio(), entry, e, s, reject))
     {
      g_last_veto = "stop-order: " + reject;
      return;
     }
   double lots = 0;
   string veto;
   if(!g_risk.CanOpen(dir, entry, s.invalidation, lots, veto))
     {
      g_journal.Log("VETO", "stop-order risk veto: " + veto);
      return;
     }
   const double tp = ComputeTp(dir, entry, s.invalidation, s.target);
   const string comment = StringFormat("WT|BOS|%.2f|SO", s.score);
   if(g_exec.PlaceStop(dir, lots, entry, s.invalidation, tp, comment))
      g_journal.Log("RISK", "sizing: " + g_risk.SizingNote());
  }

//+------------------------------------------------------------------+
void TryExecute(void)
  {
   if(g_bridge.Paused())
     {
      g_journal.Log("VETO", "authorization denied: dashboard pause");
      g_last_veto = "dashboard pause";
      return;
     }
   //--- F18 news blackout: no NEW entries near high-impact events
   string news;
   if(g_news.Blocked(news))
     {
      g_journal.Log("VETO", "authorization denied: " + news);
      g_last_veto = news;
      return;
     }
   string deny;
   if(!g_discipline.CanTrade(g_risk.Lock(), deny))
     {
      if(deny != "")
        {
         g_journal.Log("VETO", "authorization denied: " + deny);
         g_last_veto = "auth: " + deny;
        }
      return;
     }

   //--- a resting pending order owns the entry for this setup
   if(g_exec.PendingCount() > 0)
      return;

   SSetup s;
   g_discipline.GetSetup(s);

   //--- current market entry price
   const double price = (s.dir == WT_DIR_LONG)
                        ? SymbolInfoDouble(g_cfg.symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(g_cfg.symbol, SYMBOL_BID);
   const double sl = s.invalidation;
   const double tp = ComputeTp(s.dir, price, sl, s.target);

   //--- risk authorization + sizing
   double lots = 0;
   string veto;
   if(!g_risk.CanOpen(s.dir, price, sl, lots, veto))
     {
      g_journal.Log("VETO", "risk veto: " + veto);
      g_last_veto = "risk: " + veto;
      g_discipline.Consume();
      return;
     }

   //--- execute
   const string comment = StringFormat("WT|%s|%.2f",
                          s.signal == WT_SIG_QM ? "QM" : (s.signal == WT_SIG_CHOCH ? "CHOCH" : "BOS"),
                          s.score);
   if(g_exec.OpenMarket(s.dir, lots, sl, tp, comment))
     {
      g_journal.Log("RISK", "sizing: " + g_risk.SizingNote());
      g_discipline.Consume();
      g_last_veto = "";
     }
  }

//+------------------------------------------------------------------+
//| Timer: finish leftover analytics, flush journal, dashboard.      |
//+------------------------------------------------------------------+
void OnTimer(void)
  {
   //--- dashboard command bridge (file IO on timer path only)
   bool flatten_req, clear_lock_req;
   const string cmd = g_bridge.Poll(flatten_req, clear_lock_req);
   if(cmd != "")
      g_journal.Log("RECOVER", "dashboard command: " + cmd);
   if(flatten_req)
      g_exec.CloseAll("dashboard FLATTEN command");
   if(clear_lock_req)
     {
      g_risk.SetLock(WT_LOCK_NONE);
      g_flattened = false;
      g_journal.Log("RISK", "lock cleared by dashboard");
     }

   //--- v2.4 protective flattens (1 s cadence; entries are separately
   //--- blocked by the news blackout / session window)
   if(InpFridayFlattenHour > 0)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.day_of_week == 5 && dt.hour >= InpFridayFlattenHour)
        {
         if(g_risk.OpenPositions() > 0)
            g_exec.CloseAll("Friday flatten: weekend gap protection");
         if(g_exec.PendingCount() > 0)
            g_exec.CancelPending("Friday flatten");
        }
     }
   if(InpNewsFlattenMin > 0)
     {
      string ev;
      if(g_news.Upcoming(InpNewsFlattenMin, ev) &&
         (g_risk.OpenPositions() > 0 || g_exec.PendingCount() > 0))
        {
         if(g_risk.OpenPositions() > 0)
            g_exec.CloseAll("pre-news flatten: " + ev);
         if(g_exec.PendingCount() > 0)
            g_exec.CancelPending("pre-news flatten: " + ev);
        }
     }

   g_sched.RunPending(g_cfg.timer_budget_us);
   g_journal.Flush();

   //--- status snapshot for the dashboard
   g_bridge.WriteStatus(g_cfg.symbol, g_cfg.tf,
                        (int)g_risk.Lock(), (int)g_discipline.State(),
                        (int)g_structure.Trend(),
                        AccountInfoDouble(ACCOUNT_EQUITY),
                        g_risk.DayStartEquity(), g_risk.PeakEquity(),
                        g_risk.LossStreak(), g_risk.OpenPositions(),
                        g_vwap.Value(), g_profile.Poc(),
                        g_ehlers.Wave(), g_sched.AllDone());

   //--- lightweight dashboard, throttled to 1s by the timer itself
   const datetime now = TimeCurrent();
   if(now == g_last_comment)
      return;
   g_last_comment = now;

   string lock_txt = "none";
   switch(g_risk.Lock())
     {
      case WT_LOCK_DAILY_LOSS: lock_txt = "DAILY LOSS";  break;
      case WT_LOCK_STREAK:     lock_txt = "LOSS STREAK"; break;
      case WT_LOCK_TOTAL_DD:   lock_txt = "TOTAL DD";    break;
     }
   string state_txt = "NO_SETUP";
   switch(g_discipline.State())
     {
      case WT_SETUP_FORMING:   state_txt = "FORMING";   break;
      case WT_SETUP_CONFIRMED: state_txt = "CONFIRMED"; break;
      case WT_SETUP_ACTIVE:    state_txt = "ACTIVE";    break;
      case WT_SETUP_EXPIRED:   state_txt = "EXPIRED";   break;
     }
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   Comment(StringFormat(
      "WiseTrader | %s %s\n" +
      "Trend: %s | Setup: %s | Lock: %s\n" +
      "VWAP: %.2f  POC: %.2f  VA: %.2f-%.2f  Cycle: %.2f\n" +
      "Equity: %.2f  DayStart: %.2f  Peak: %.2f  Streak: %d\n" +
      "Analytics: %s | Journal buffered: %d\n" +
      "Last veto: %s",
      g_cfg.symbol, EnumToString(g_cfg.tf),
      g_structure.Trend() == WT_DIR_LONG ? "BULL" : (g_structure.Trend() == WT_DIR_SHORT ? "BEAR" : "-"),
      state_txt, lock_txt,
      g_vwap.Value(), g_profile.Poc(), g_profile.Val(), g_profile.Vah(),
      g_ehlers.Wave(),
      eq, g_risk.DayStartEquity(), g_risk.PeakEquity(), g_risk.LossStreak(),
      g_sched.AllDone() ? "up to date" : "catching up...",
      g_journal.Pending(),
      g_last_veto == "" ? "-" : g_last_veto));
  }

//+------------------------------------------------------------------+
//| Track closed deals for the consecutive-loss counter.             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != g_cfg.magic)
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != g_cfg.symbol)
      return;

   //--- pending-order fill (v2.1): the resting order was the entry
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
     {
      const long dtype = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
      const ENUM_WT_DIR dir = (dtype == DEAL_TYPE_BUY) ? WT_DIR_LONG : WT_DIR_SHORT;
      //--- stop-order fill IS the break: consume the level so the bar
      //--- close cannot fire a duplicate signal for the same move
      if(g_cfg.entry_mode == WT_ENTRY_STOP_ORDER)
         g_structure.ConsumeLevel(dir);
      g_discipline.Consume();
      g_journal.Log("ORDER", StringFormat("entry fill deal #%I64u %s %.2f @ %.5f",
                    trans.deal, dir == WT_DIR_LONG ? "BUY" : "SELL",
                    HistoryDealGetDouble(trans.deal, DEAL_VOLUME),
                    HistoryDealGetDouble(trans.deal, DEAL_PRICE)));
      return;
     }
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;
   const double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                    + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                    + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   g_risk.OnDealClosed(pnl);
   g_journal.Log("RISK", StringFormat("deal closed pnl=%.2f streak=%d lock=%d",
                 pnl, g_risk.LossStreak(), (int)g_risk.Lock()));
  }
//+------------------------------------------------------------------+
