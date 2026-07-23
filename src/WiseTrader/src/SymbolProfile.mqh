//+------------------------------------------------------------------+
//| WiseTrader - SymbolProfile.mqh                                   |
//| Per-symbol parameter overrides, applied once in OnInit.          |
//|                                                                  |
//| Why this exists: InpProfileBin (volume-profile bin size) is a    |
//| fixed PRICE-UNIT constant. A value tuned for XAUUSD's ~$4300     |
//| price scale (0.20) is degenerate on EURUSD's ~1.16 scale - it    |
//| collapses the whole session's volume into one or two bins,       |
//| destroying the POC/VAH/VAL shape (root-caused 2026-07: the       |
//| EURUSD cross-symbol test flipped from PF 0.85 to PF 1.12 once    |
//| retested with a corrected bin). Every other distance input in    |
//| the EA is already ATR-relative and self-scales; this is the      |
//| one absolute-price-unit exception, so it is the one exception    |
//| that needs a per-symbol table instead of a universal default.    |
//|                                                                  |
//| This table starts with only what campaign evidence has actually |
//| validated (or, for GBPUSD, a documented seed value pending its   |
//| own campaign - see docs/WiseTrader_Feature_Log.xlsx "Document    |
//| Log" / regression_history.csv for the evidence trail). Extend    |
//| ApplySymbolOverrides() with more SSettings fields (min_adx,      |
//| vol_risk_floor, session hours, Friday flatten hour, ...) as each |
//| symbol's own ablation series concludes - do not guess ahead of   |
//| evidence; leave a field alone (inherits the EA's input default)  |
//| until a campaign says otherwise.                                 |
//+------------------------------------------------------------------+
#ifndef WT_SYMBOLPROFILE_MQH
#define WT_SYMBOLPROFILE_MQH

#include "Config.mqh"

// Matches loosely on symbol name so broker suffixes (XAUUSD.a, EURUSD-ECN,
// EURUSDm, ...) still hit the right row instead of silently falling through
// to the XAUUSD-tuned defaults.
bool SymbolIs(const string symbol, const string needle)
  {
   return (StringFind(symbol, needle) >= 0);
  }

// Applies known-good per-symbol overrides on top of whatever the EA inputs
// already loaded into cfg. profile_bin is passed separately because it
// belongs to CSessionProfile, not SSettings. Returns a short note for the
// journal describing what (if anything) was overridden, for auditability -
// a live/demo run should always be traceable to which row fired.
string ApplySymbolOverrides(const string symbol, SSettings &cfg, double &profile_bin)
  {
   string note = "none (defaults)";

   if(SymbolIs(symbol, "XAU"))
     {
      // Gold: the EA's shipped defaults (A2_tuned, v2.42) ARE the
      // XAUUSD-tuned values. No override - this row exists so the table is
      // self-documenting rather than silently having "no XAU entry".
      note = "XAUUSD: EA defaults are already tuned for this symbol";
     }
   else if(SymbolIs(symbol, "XAG"))
     {
      // Silver: validated 2026-07-17 cross-symbol gauntlet run with the
      // gold-scaled profile_bin (0.20) unmodified - PF 1.39, expectancy
      // $7.98, matched XAUUSD closely. 0.20 isn't degenerate at silver's
      // ~$28-35 price scale, so no override needed (yet - other fields
      // untested per-symbol until its own ablation series runs).
      note = "XAGUSD: EA defaults validated as-is (2026-07-17 gauntlet, PF 1.39)";
     }
   else if(SymbolIs(symbol, "EUR") && SymbolIs(symbol, "USD"))
     {
      // EURUSD: validated 2026-07-17 - InpProfileBin=0.20 (gold-scaled) is
      // degenerate at EURUSD's ~1.16 price scale (PF 0.85, net -$182);
      // 0.0002 fixes the volume-profile shape (PF 1.12, net +$325).
      profile_bin = 0.0002;
      note = "EURUSD: profile_bin 0.20 -> 0.0002 (2026-07-17 E2 retest, PF 0.85 -> 1.12)";
     }
   else if(SymbolIs(symbol, "GBP") && SymbolIs(symbol, "USD"))
     {
      // GBPUSD: NOT YET TESTED as of 2026-07-20. Seeded from EURUSD's
      // validated value since GBPUSD trades at a similar price scale
      // (~1.25-1.30 vs EURUSD's ~1.16) - same order of magnitude, so this
      // is a reasoned starting point, not a guess pulled from nothing, but
      // it is UNCONFIRMED. Do not treat GBPUSD results as trustworthy until
      // its own ablation series (see tests/configs/G*.set) has run and this
      // comment has been updated with real evidence.
      profile_bin = 0.0002;
      note = "GBPUSD: profile_bin 0.20 -> 0.0002 (SEEDED from EURUSD, UNCONFIRMED - own campaign pending)";
     }

   return note;
  }

#endif // WT_SYMBOLPROFILE_MQH
