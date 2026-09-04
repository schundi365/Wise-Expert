//+------------------------------------------------------------------+
//| WiseTrader - MomentumBreak.mqh                                   |
//| F59: aggressive, volume-CONFIRMED momentum-expansion entry.       |
//|                                                                  |
//| The rest of the engine treats a high-sigma bar as noise (F16     |
//| outlier mask vetoes it). This is the deliberate INVERSION: a bar |
//| that expands sharply in one direction AND is backed by real      |
//| relative volume is the start of a run we want to ride, not a     |
//| fake-break to avoid. Volume is what separates the two - hence     |
//| "trade it cautiously by considering volumes".                    |
//|                                                                  |
//| Emits a normal SSetup (signal = WT_SIG_MOMENTUM) that flows       |
//| through the SAME risk/exec rails as every other entry, so the    |
//| hard stop is MANDATORY and enforced by CRiskManager::CanOpen      |
//| (a zero/absent stop is rejected before any order is sent). The    |
//| stop here is intentionally TIGHT (aggressive entries demand it):  |
//| the opposite extreme of the expansion bar, floored to a minimum  |
//| ATR distance so it can't be placed inside the noise.             |
//|                                                                  |
//| OFF by default (use_mom_break=false). Candidate, unvalidated -    |
//| momentum entries collapse OOS more than most (see F52/F53), so    |
//| this must clear the full gauntlet before it earns a demo slot.   |
//+------------------------------------------------------------------+
#ifndef WT_MOMENTUMBREAK_MQH
#define WT_MOMENTUMBREAK_MQH

#include "Config.mqh"
#include "Outliers.mqh"

class CMomentumBreak
  {
private:
   SSettings         m_cfg;

   double            Hi(const int sh) const { return iHigh(m_cfg.symbol, m_cfg.tf, sh); }
   double            Lo(const int sh) const { return iLow(m_cfg.symbol, m_cfg.tf, sh); }
   double            Cl(const int sh) const { return iClose(m_cfg.symbol, m_cfg.tf, sh); }

public:
   void              Init(const SSettings &cfg) { m_cfg = cfg; }

   // Evaluate the just-closed bar (shift 1) as a momentum-expansion entry.
   // Requires: expansion (outlier true-range Z >= mom_expansion_z),
   // a strong directional close (in the top/bottom mom_close_frac of the
   // bar range), and participation (relvol >= mom_min_relvol). 'expansion_z'
   // and 'relvol' are passed in (already computed by the EA's shared
   // Outliers/RelVolume instances) to avoid duplicate indicator reads.
   // Fills 'out' with a hard-stopped setup and returns true on a signal.
   bool              Scan(const double atr, const double expansion_z,
                          const double relvol, SSetup &out, string &reject)
     {
      reject = "";
      if(!m_cfg.use_mom_break)
         return false;
      if(atr <= 0)
        { reject = "mom: atr unavailable"; return false; }

      //--- 1) expansion: the bar's true range is a statistical outlier.
      //--- Reuse the SAME modified-Z the F16 mask computes; here a high
      //--- value is the trigger, not a veto.
      if(expansion_z < m_cfg.mom_expansion_z)
        { reject = StringFormat("mom: no expansion Z %.1f < %.1f", expansion_z, m_cfg.mom_expansion_z); return false; }

      const double hi = Hi(1), lo = Lo(1), cl = Cl(1);
      const double range = hi - lo;
      if(range <= 0)
        { reject = "mom: zero range"; return false; }

      //--- 2) directional close: close sits in the top/bottom fraction of
      //--- the bar's range -> the expansion resolved with conviction, not
      //--- a rejection wick. pos = 0 at the low, 1 at the high.
      const double pos = (cl - lo) / range;
      ENUM_WT_DIR dir = WT_DIR_NONE;
      if(pos >= 1.0 - m_cfg.mom_close_frac)      dir = WT_DIR_LONG;
      else if(pos <= m_cfg.mom_close_frac)       dir = WT_DIR_SHORT;
      else
        { reject = StringFormat("mom: weak close pos %.2f (need <=%.2f or >=%.2f)",
                                pos, m_cfg.mom_close_frac, 1.0 - m_cfg.mom_close_frac); return false; }

      //--- 3) participation: the move must have real volume behind it.
      //--- relvol == -1 means no baseline -> stand down (never trade a
      //--- momentum spike we can't confirm), consistent with RelVolume.
      if(relvol < 0)
        { reject = "mom: no relvol baseline - stand down"; return false; }
      if(relvol < m_cfg.mom_min_relvol)
        { reject = StringFormat("mom: thin volume relVol %.2f < %.2f", relvol, m_cfg.mom_min_relvol); return false; }

      //--- build the setup. Entry reference = the expansion bar's close
      //--- (the EA fills at current market on execution). The HARD STOP is
      //--- the opposite extreme of the expansion bar, floored to a minimum
      //--- ATR distance so an unusually small bar can't place a stop inside
      //--- the noise. The engine's Validate() applies the global ATR stop
      //--- floor + min-RR on top of this; CanOpen() then sizes and can
      //--- veto - a stopless F59 position is impossible by construction.
      SetupReset(out);
      out.signal   = WT_SIG_MOMENTUM;
      out.dir      = dir;
      out.entry    = cl;
      out.bar_time = iTime(m_cfg.symbol, m_cfg.tf, 1);
      out.target   = 0;   // RR fallback + ATR cap assigned by the executor

      const double floor_dist = m_cfg.mom_stop_atr * atr;
      if(dir == WT_DIR_LONG)
        {
         double stop = lo;                          // opposite extreme
         if(cl - stop < floor_dist) stop = cl - floor_dist;
         out.invalidation = stop;
        }
      else
        {
         double stop = hi;
         if(stop - cl < floor_dist) stop = cl + floor_dist;
         out.invalidation = stop;
        }

      out.evidence = StringFormat("MOM %s expZ=%.1f pos=%.2f relVol=%.2f stopATR=%.1f",
                        dir == WT_DIR_LONG ? "long" : "short",
                        expansion_z, pos, relvol, m_cfg.mom_stop_atr);
      return true;
     }
  };

#endif // WT_MOMENTUMBREAK_MQH
