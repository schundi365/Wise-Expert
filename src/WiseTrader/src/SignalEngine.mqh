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

   double            Adx(void)
     {
      double buf[];
      if(m_adx_handle == INVALID_HANDLE ||
         CopyBuffer(m_adx_handle, MAIN_LINE, 1, 1, buf) != 1)
         return -1.0;   // unavailable: gate stands down gracefully
      return buf[0];
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
         if(aligned) { score += 0.20; ev += StringFormat("|CycleTurn w=%.2f<-%.2f", w, wp); }
        }

      //--- trend strength bonus: strong regime rewards continuation entries
      const double adx = Adx();
      if(adx > 30 && s.signal == WT_SIG_BOS)
        { score += 0.10; ev += StringFormat("|ADX=%.0f", adx); }

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
