//+------------------------------------------------------------------+
//| WiseTrader - SignalEngine.mqh                                    |
//| Turns structure events and QM patterns into scored setups.       |
//| Confluence scoring combines: signal strength, volume-profile     |
//| level proximity, VWAP side, and Ehlers cycle phase agreement.    |
//| Every emitted setup carries its evidence string for the journal. |
//+------------------------------------------------------------------+
#ifndef WT_SIGNALENGINE_MQH
#define WT_SIGNALENGINE_MQH

#include "Config.mqh"
#include "Structure.mqh"
#include "Quasimodo.mqh"
#include "Vwap.mqh"
#include "VolumeProfile.mqh"
#include "Ehlers.mqh"

class CSignalEngine
  {
private:
   SSettings         m_cfg;
   int               m_adx_handle;  // ADX(14) trend-strength gate
   int               m_rsi_handle;  // RSI(momentum_period) confluence (v2.44, F52)
   int               m_atr14_handle; // ATR(14) for vol-regime confluence (v2.47, F55)
   int               m_atr100_handle; // ATR(100) baseline for vol-regime confluence
   int               m_mtf_ma_handle; // higher-TF EMA for MTF agreement (v2.49, F57)

   double            Adx(void)
     {
      double buf[];
      if(m_adx_handle == INVALID_HANDLE ||
         CopyBuffer(m_adx_handle, MAIN_LINE, 1, 1, buf) != 1)
         return -1.0;   // unavailable: gate stands down gracefully
      return buf[0];
     }

   // F52: sustained-pressure read over momentum_period bars (default 14),
   // independent of structure's swing-based break detection. -1 = unavailable.
   double            Momentum(void)
     {
      double buf[];
      if(m_rsi_handle == INVALID_HANDLE ||
         CopyBuffer(m_rsi_handle, 0, 1, 1, buf) != 1)
         return -1.0;
      return buf[0];
     }

   // F53: OLS slope + R^2 of closes over the last 'n' CLOSED bars (shift
   // 1..n, no lookahead). Catches grinding trends that never produce a
   // clean swing break - structure's own blind spot. Returns false if
   // not enough history is available yet.
   bool              RegressionSlope(const int n, double &slope, double &r2)
     {
      double closes[];
      ArraySetAsSeries(closes, true);
      if(CopyClose(m_cfg.symbol, m_cfg.tf, 1, n, closes) != n)
         return false;
      //--- x = 0..n-1 in chronological order (oldest first); closes[] is
      //--- series-ordered (index 0 = most recent), so reverse the mapping.
      double xbar = (n - 1) / 2.0, ybar = 0.0;
      for(int i = 0; i < n; i++)
         ybar += closes[n - 1 - i];
      ybar /= n;
      double sxy = 0.0, sxx = 0.0, syy = 0.0;
      for(int i = 0; i < n; i++)
        {
         const double y  = closes[n - 1 - i];
         const double dx = i - xbar;
         const double dy = y - ybar;
         sxy += dx * dy;
         sxx += dx * dx;
         syy += dy * dy;
        }
      if(sxx <= 0 || syy <= 0)
         return false;
      slope = sxy / sxx;
      const double r = sxy / MathSqrt(sxx * syy);
      r2 = r * r;
      return true;
     }

   // F55: ATR14/ATR100 ratio - a SEPARATE read from Risk.mqh's own handles
   // (that one drives position sizing, treating high ratio as a reason to
   // shrink risk; this one treats expansion-after-squeeze as a movement
   // signal in its own right). -1 = unavailable.
   double            VolRatio(void)
     {
      double f[], s[];
      if(m_atr14_handle == INVALID_HANDLE || m_atr100_handle == INVALID_HANDLE ||
         CopyBuffer(m_atr14_handle, 0, 1, 1, f) != 1 ||
         CopyBuffer(m_atr100_handle, 0, 1, 1, s) != 1 || s[0] <= 0)
         return -1.0;
      return f[0] / s[0];
     }

   // F56: variance-ratio persistence test (Lo-MacKinlay style, non-
   // overlapping blocks for simplicity). VR > 1 = trending/persistent
   // returns, VR < 1 = mean-reverting, VR ~ 1 = random walk. Answers "is
   // this regime the kind where a bar-based breakout deserves trust at
   // all" - independent of structure's own break-detection logic.
   // Returns -1 if there isn't enough clean history.
   double            PersistenceRatio(const int lookback, const int q)
     {
      if(q < 2 || lookback < q * 5)
         return -1.0;
      double closes[];
      ArraySetAsSeries(closes, true);
      if(CopyClose(m_cfg.symbol, m_cfg.tf, 1, lookback + 1, closes) != lookback + 1)
         return -1.0;
      //--- chronological 1-period log returns, oldest to newest
      double r[];
      ArrayResize(r, lookback);
      for(int i = 0; i < lookback; i++)
        {
         const double newer = closes[lookback - 1 - i];
         const double older = closes[lookback - i];
         if(older <= 0 || newer <= 0)
            return -1.0;
         r[i] = MathLog(newer / older);
        }
      double mu = 0.0;
      for(int i = 0; i < lookback; i++) mu += r[i];
      mu /= lookback;
      double var1 = 0.0;
      for(int i = 0; i < lookback; i++) var1 += (r[i] - mu) * (r[i] - mu);
      var1 /= (lookback - 1);
      if(var1 <= 0)
         return -1.0;
      //--- non-overlapping q-period sums
      const int m = lookback / q;
      if(m < 2)
         return -1.0;
      double Rk[];
      ArrayResize(Rk, m);
      for(int k = 0; k < m; k++)
        {
         double s = 0.0;
         for(int j = 0; j < q; j++) s += r[k * q + j];
         Rk[k] = s;
        }
      double muq = 0.0;
      for(int k = 0; k < m; k++) muq += Rk[k];
      muq /= m;
      double varq = 0.0;
      for(int k = 0; k < m; k++) varq += (Rk[k] - muq) * (Rk[k] - muq);
      varq /= (m - 1);
      return varq / (q * var1);
     }

   // F57: higher-TF bias via close vs EMA (e.g. H1 close vs H1 EMA50).
   // Catches "M15 broke a level but H1 is still ranging/opposed" - a
   // failure mode no amount of extra M15 bar-counting can see. Returns
   // WT_DIR_NONE if the feature is off or data isn't ready yet.
   // v2.51: 'dbg' out-param pinpoints exactly which step is failing - two
   // prior fixes (retry-on-invalid-handle, then asking to reload H1
   // history) both still produced zero MTF tags across every evaluated
   // setup, so guessing further isn't productive; log the real cause.
   // Prime the higher-TF series so the tester synchronizes it. In a
   // single-symbol M15 backtest the tester only builds H1 history once the
   // EA actually ACCESSES that timeframe (per MT5 tester docs: the run
   // pauses to download missing symbol/TF data on first access). Creating
   // the iMA handle alone did NOT trigger this on build 6093 - iMA returned
   // 4805 (ERR_INDICATOR_CANNOT_CREATE) for the whole run. An explicit
   // history touch (CopyRates) forces the sync; the handle then succeeds.
   // Returns true once at least one HTF bar is available.
   bool              PrimeMtfHistory(void)
     {
      MqlRates r[];
      return CopyRates(m_cfg.symbol, m_cfg.mtf_tf, 1, 1, r) == 1;
     }

   ENUM_WT_DIR       MtfBias(string &dbg)
     {
      if(m_mtf_ma_handle == INVALID_HANDLE)
        {
         //--- touch H1 history first so the tester builds it, THEN create
         //--- the handle. Lazy-retry every call while the handle is invalid
         //--- (self-healing) - the tester may not have the H1 data ready on
         //--- the very first evaluated bar.
         if(!PrimeMtfHistory())
           { dbg = StringFormat("htf_history_not_ready err=%d", GetLastError()); return WT_DIR_NONE; }
         m_mtf_ma_handle = iMA(m_cfg.symbol, m_cfg.mtf_tf, m_cfg.mtf_ma_period, 0, MODE_EMA, PRICE_CLOSE);
         if(m_mtf_ma_handle == INVALID_HANDLE)
           { dbg = StringFormat("handle_invalid err=%d", GetLastError()); return WT_DIR_NONE; }
        }
      const double htf_close = iClose(m_cfg.symbol, m_cfg.mtf_tf, 1);
      if(htf_close <= 0)
        { dbg = StringFormat("htf_close<=0 val=%.5f err=%d", htf_close, GetLastError()); return WT_DIR_NONE; }
      double ma[];
      const int copied = CopyBuffer(m_mtf_ma_handle, 0, 1, 1, ma);
      if(copied != 1)
        { dbg = StringFormat("copybuffer_ret=%d err=%d", copied, GetLastError()); return WT_DIR_NONE; }
      dbg = StringFormat("close=%.2f ma=%.2f", htf_close, ma[0]);
      if(htf_close > ma[0]) return WT_DIR_LONG;
      if(htf_close < ma[0]) return WT_DIR_SHORT;
      return WT_DIR_NONE;
     }

   // score one candidate 0..1 and append evidence.
   // v1.8 rebalance: VWAP side is nearly free for breakouts (0.10, was
   // 0.20); cycle credit requires the wave to be TURNING with the trade,
   // not already at its extreme (the old check bought cycle tops).
   double            Score(SSetup &s, CSessionVwap &vwap, CSessionProfile &prof,
                           CEhlers &ehlers, const double atr)
     {
      double score = 0.0;
      string ev = s.evidence;

      //--- base signal weight. v1.9: CHoCH demoted to BOS level - journal
      //--- data (Jan-Mar 2026, XAUUSD) showed CHoCH entries net-negative
      //--- while BOS carried the P&L; counter-trend breaks get no premium.
      if(s.signal == WT_SIG_QM)        score += 0.35;
      else                             score += 0.30;   // BOS, CHoCH

      //--- volume profile: near a ranked level (POC/VAH/VAL) = defended zone
      if(prof.Ready() && prof.HasData() && atr > 0)
        {
         const double d = prof.NearestLevelDistance(s.entry);
         if(d < 0.75 * atr) { score += 0.25; ev += StringFormat("|VPnode d=%.2f", d); }
         else if(d < 1.50 * atr) { score += 0.10; ev += "|VPnear"; }
        }

      //--- VWAP side: weak confirmation for breakouts (correlated factor)
      if(vwap.Ready() && vwap.HasData())
        {
         const double v = vwap.Value();
         const bool aligned = (s.dir == WT_DIR_LONG && s.entry > v) ||
                              (s.dir == WT_DIR_SHORT && s.entry < v);
         if(aligned) { score += 0.10; ev += "|VWAPside"; }
        }

      //--- Ehlers cycle: reward entering while the wave turns WITH the
      //--- trade and is not yet extended (w in the first ~80% of the swing)
      if(ehlers.Ready())
        {
         const double w  = ehlers.Wave();
         const double wp = ehlers.WavePrev();
         const bool aligned = (s.dir == WT_DIR_LONG  && w > wp && w <  0.8) ||
                              (s.dir == WT_DIR_SHORT && w < wp && w > -0.8);
         if(aligned) { score += m_cfg.cycle_turn_weight; ev += StringFormat("|CycleTurn w=%.2f<-%.2f", w, wp); }
        }

      //--- trend strength bonus: strong regime rewards continuation entries
      const double adx = Adx();
      if(adx > 30 && s.signal == WT_SIG_BOS)
        { score += 0.10; ev += StringFormat("|ADX=%.0f", adx); }

      //--- F52 (candidate, OFF by default): sustained pressure over
      //--- momentum_period bars agreeing with trade direction. Distinct
      //--- from structure (did price break a level) and from ADX (is
      //--- there a trend at all) - this asks "is the move actually
      //--- building, not just the last 3-4 candles."
      if(m_cfg.use_momentum)
        {
         const double rsi = Momentum();
         if(rsi >= 0)
           {
            const bool aligned = (s.dir == WT_DIR_LONG  && rsi > m_cfg.momentum_long_th) ||
                                 (s.dir == WT_DIR_SHORT && rsi < m_cfg.momentum_short_th);
            if(aligned) { score += m_cfg.momentum_weight; ev += StringFormat("|RSI=%.0f", rsi); }
           }
        }

      //--- F53 (candidate, OFF by default): OLS trend slope over
      //--- regression_lookback bars (default 30), gated on R^2 so a flat
      //--- or noisy window can't falsely claim a trend. Catches grinding
      //--- moves that never trip a structure swing break.
      if(m_cfg.use_regression)
        {
         double slope = 0.0, r2 = 0.0;
         if(RegressionSlope(m_cfg.regression_lookback, slope, r2) && r2 >= m_cfg.regression_min_r2)
           {
            const bool aligned = (s.dir == WT_DIR_LONG && slope > 0) ||
                                 (s.dir == WT_DIR_SHORT && slope < 0);
            if(aligned) { score += m_cfg.regression_weight; ev += StringFormat("|Slope=%.4f R2=%.2f", slope, r2); }
           }
        }

      //--- F55 (candidate, OFF by default): ATR14/ATR100 expansion as a
      //--- movement signal in its own right, independent of direction and
      //--- independent of where swing pivots happen to fall. Distinct from
      //--- Risk.mqh's use of the same ratio family for sizing.
      if(m_cfg.use_vol_regime)
        {
         const double vr = VolRatio();
         if(vr >= m_cfg.vol_regime_min_ratio)
            { score += m_cfg.vol_regime_weight; ev += StringFormat("|VolExp=%.2f", vr); }
        }

      //--- F56 (candidate, OFF by default): variance-ratio persistence.
      //--- Directionless, like F55 - asks whether THIS regime is the kind
      //--- where a bar-based breakout deserves trust, independent of
      //--- structure's own break-detection logic.
      if(m_cfg.use_persistence)
        {
         const double vr = PersistenceRatio(m_cfg.persistence_lookback, m_cfg.persistence_q);
         if(vr >= m_cfg.persistence_min_vr)
            { score += m_cfg.persistence_weight; ev += StringFormat("|VR=%.2f", vr); }
        }

      //--- F57 (candidate, OFF by default): does a higher timeframe agree
      //--- with the trade direction. Different failure mode than every
      //--- other signal here - all of them read the SAME timeframe more
      //--- carefully; this one asks a DIFFERENT timeframe entirely.
      if(m_cfg.use_mtf)
        {
         string dbg = "";
         const ENUM_WT_DIR bias = MtfBias(dbg);
         //--- v2.51 temporary diagnostic - always logged (not just on
         //--- alignment) so the journal shows the real cause instead of
         //--- staying silent. Remove once F57's failure mode is confirmed.
         ev += "|MTFdbg:" + dbg;
         if(bias == s.dir)
            { score += m_cfg.mtf_weight; ev += StringFormat("|MTF%s", EnumToString(m_cfg.mtf_tf)); }
        }

      s.evidence = ev;
      return MathMin(score, 1.0);
     }

   // enforce minimum stop distance and minimum RR; may adjust or reject
   bool              Validate(SSetup &s, const double atr)
     {
      if(atr <= 0 || s.dir == WT_DIR_NONE)
         return false;
      const double floor_dist = m_cfg.atr_stop_floor_mult * atr;
      double stop_dist = MathAbs(s.entry - s.invalidation);
      if(stop_dist < floor_dist)
        {
         //--- widen the stop to the volatility floor
         s.invalidation = (s.dir == WT_DIR_LONG) ? s.entry - floor_dist
                                                 : s.entry + floor_dist;
         stop_dist = floor_dist;
         s.evidence += "|StopFloored";
        }
      //--- reward:risk check (target may be 0 = RR fallback assigned later)
      if(s.target != 0)
        {
         const double reward = MathAbs(s.target - s.entry);
         if(reward / stop_dist < m_cfg.min_rr)
           {
            s.evidence += "|RRfail";
            return false;
           }
        }
      return true;
     }

public:
   void              Init(const SSettings &cfg)
     {
      m_cfg = cfg;
      m_adx_handle = iADX(m_cfg.symbol, m_cfg.tf, 14);
      m_rsi_handle = iRSI(m_cfg.symbol, m_cfg.tf, m_cfg.momentum_period, PRICE_CLOSE);
      m_atr14_handle  = iATR(m_cfg.symbol, m_cfg.tf, 14);
      m_atr100_handle = iATR(m_cfg.symbol, m_cfg.tf, 100);
      //--- only pull higher-TF history when the feature is actually on -
      //--- avoids the "history cache build error" the H1-InpTF ablation
      //--- configs hit, for every run where this feature is off (default).
      //--- v2.52: touch H1 history BEFORE creating the handle so the tester
      //--- synchronizes the secondary TF (single-symbol M15 backtests only
      //--- build H1 on first access - without this iMA() returned 4805 for
      //--- the entire run). If it's still not ready at init, MtfBias()
      //--- lazy-retries (both prime + handle) on every call.
      m_mtf_ma_handle = INVALID_HANDLE;
      if(m_cfg.use_mtf && PrimeMtfHistory())
         m_mtf_ma_handle = iMA(m_cfg.symbol, m_cfg.mtf_tf, m_cfg.mtf_ma_period, 0, MODE_EMA, PRICE_CLOSE);
     }

   // Evaluate one structure break event into a scored setup, using
   // 'entry_price' as the reference entry (M15 close, M1 close, or a
   // stop-order level). Shared by Poll (M15 close path) and the EA's
   // early-entry paths (v2.1). Returns false with a reject reason.
   bool              EvaluateBreak(CMarketStructure &ms, CSessionVwap &vwap,
                                   CSessionProfile &prof, CEhlers &ehlers,
                                   const double atr, const double relvol,
                                   const double entry_price,
                                   const SStructureEvent &e,
                                   SSetup &s, string &reject_reason)
     {
      //--- chop stand-down (F15 lite): breakout logic needs a trending
      //--- regime; ADX below the floor = range boundaries, not breaks
      const double adx = Adx();
      if(m_cfg.min_adx > 0 && adx >= 0 && adx < m_cfg.min_adx)
        {
         reject_reason = StringFormat("regime: chop ADX %.1f < %.1f", adx, m_cfg.min_adx);
         return false;
        }
      //--- F10 "in play" gate: a break without participation is the
      //--- classic fake-break; require volume vs the same time of day
      if(m_cfg.min_relvol > 0 && relvol >= 0 && relvol < m_cfg.min_relvol)
        {
         reject_reason = StringFormat("volume: relVol %.2f < %.2f", relvol, m_cfg.min_relvol);
         return false;
        }

      SetupReset(s);
      s.signal   = e.type;
      s.dir      = e.dir;
      s.bar_time = e.bar_time;
      s.entry    = entry_price;
      s.level    = e.level;
      s.target   = 0;   // RR fallback set by executor
      s.evidence = StringFormat("%s %s lvl=%.2f",
                     (e.type == WT_SIG_BOS ? "BOS" : "CHoCH"),
                     (e.dir == WT_DIR_LONG ? "long" : "short"), e.level);
      if(relvol >= 0)
         s.evidence += StringFormat("|RelVol=%.2f", relvol);

      //--- max-chase veto: if the entry reference is too far beyond the
      //--- level, don't buy the extension - wait for the pullback.
      //--- CHoCH ALWAYS waits for the retest (v1.9): counter-trend
      //--- breaks bought at market were the losing bucket in the data.
      //--- max_chase_atr=0 disables ALL retest logic (regression testing).
      if(atr > 0 && m_cfg.max_chase_atr > 0 &&
         (e.type == WT_SIG_CHOCH ||
          MathAbs(s.entry - s.level) > m_cfg.max_chase_atr * atr))
        {
         s.pending_retest = true;
         s.retest_px = (s.dir == WT_DIR_LONG)
                       ? s.level + m_cfg.retest_tol_atr * atr
                       : s.level - m_cfg.retest_tol_atr * atr;
         s.entry = s.retest_px;   // score/validate at the retest price
         s.evidence += StringFormat("|Retest@%.2f", s.retest_px);
        }

      //--- invalidation anchored to the FINAL entry price, so a
      //--- retest setup can never carry a stop on the wrong side
      s.invalidation = (e.dir == WT_DIR_LONG) ? ms.ProtectiveLow(s.entry)
                                              : ms.ProtectiveHigh(s.entry);
      if(s.invalidation <= 0 || !Validate(s, atr))
        {
         reject_reason = "break setup failed validation [" + s.evidence + "]";
         return false;
        }
      s.score = Score(s, vwap, prof, ehlers, atr);
      if(s.score < m_cfg.min_score)
        {
         reject_reason = StringFormat("score %.2f < %.2f [%s]",
                                      s.score, m_cfg.min_score, s.evidence);
         return false;
        }
      return true;
     }

   // Poll all detectors on the new closed bar; emit best setup >= threshold.
   // 'relvol' = time-of-day relative volume of the signal bar (-1 = no
   // baseline available, gate stands down). Returns true if 'out' is
   // a tradeable setup.
   bool              Poll(CMarketStructure &ms, CQuasimodo &qm,
                          CSessionVwap &vwap, CSessionProfile &prof,
                          CEhlers &ehlers, const double atr, const double relvol,
                          SSetup &out, string &reject_reason)
     {
      SSetup best;
      SetupReset(best);
      reject_reason = "";

      //--- candidate 1: structure event (BOS/CHoCH)
      if(ms.HasEvent())
        {
         SStructureEvent e;
         ms.GetEvent(e);
         SSetup s;
         if(EvaluateBreak(ms, vwap, prof, ehlers, atr, relvol,
                          iClose(m_cfg.symbol, m_cfg.tf, 1), e, s, reject_reason))
            if(s.score > best.score)
               best = s;
        }

      //--- candidate 2: Quasimodo
        {
         SSetup s;
         if(qm.Scan(ms, atr, s) && Validate(s, atr))
           {
            s.score = Score(s, vwap, prof, ehlers, atr);
            if(s.score > best.score)
               best = s;
           }
        }

      if(best.signal == WT_SIG_NONE)
         return false;
      if(best.score < m_cfg.min_score)
        {
         reject_reason = StringFormat("score %.2f < %.2f [%s]",
                                      best.score, m_cfg.min_score, best.evidence);
         return false;
        }
      out = best;
      return true;
     }
  };

#endif // WT_SIGNALENGINE_MQH
