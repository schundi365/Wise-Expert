//+------------------------------------------------------------------+
//| GridHedge.mq5   v3.00                                            |
//| JNS-style grid/hedging EA. Dual BUY/SELL grids, per-level         |
//| parameters, code-managed exits, full interactive dashboard.       |
//|                                                                  |
//| IMPORTANT: the control meanings below are MY interpretation of a  |
//| sensible grid EA (from the JNS panel's abbreviations). They are   |
//| NOT reverse-engineered from the JNS binary (that is compiled,     |
//| packed, and a paid product). If your JNS does something different |
//| for a given control, tell me and I'll adjust that behaviour.      |
//|                                                                  |
//| Exit model is grounded in the real trade report (naked entries,   |
//| code profit-close ~70pt, keep-top-2 hedge, unstopped losers).     |
//| The SAFETY floor (max levels / floating-loss / equity stop) is    |
//| the only thing bounding the martingale tail - keep it on.         |
//+------------------------------------------------------------------+
#property copyright "Wise Trader project - GridHedge"
#property version   "3.00"
#property description "JNS-style grid EA: per-level grid table, ST/PU/CL/SY/REP controls, Start/Target/SL basket, live position table, safety floor."

#include <Trade/Trade.mqh>

#define LVLS 4     // grid levels per side: index 0=Gap2, 1=Gap3, 2=Gap4, 3=ProS

//--- inputs (seed values; panel edits them live) --------------------
input group "Base (seeds level 1 + defaults). NOTE: inputs are POINTS; the panel shows/edits PIPS (points/10)."
input double InpLot          = 0.10;    // Base lot per position
input int    InpGapPoints    = 500;     // Base gap, POINTS (500 pts = 50.00 pips on panel)
input double InpTpMoney      = 6.0;     // Profit: close each position at this MONEY profit (£, panel Profit/Tgt = 6; configurable)
input double InpLockMoney     = 50.0;   // Lock/Book: close/book at this MONEY (£, panel Lock/Book = 50; configurable, 0 = off)
input bool   InpTradeBuy     = true;    // Enable BUY side at start
input bool   InpTradeSell    = true;    // Enable SELL side at start

input group "Management (Prot / B+S)"
input int    InpProtPoints   = 200;     // Prot: arm break-even once position +this pts (200 = 20.00 pips, panel Prot)
input int    InpTrailStepPoints = 100;  // Trailing step after break-even, points (100 = 10.00 pips) - the trail distance
input int    InpBeOffsetPoints = 10;    // Break-even offset beyond entry, points
input bool   InpHelperOn      = false;  // B+S / S+B: Buy+Sell helper ON/OFF (open an opposite-side helper leg on new entries)

input group "Basket (Start / Target / SL) - JNS Target = book winners keep top-2"
input double InpBuyStart     = 0.0;     // BUY Start price: don't seed the first BUY until price <= this (0 = start at market)
input double InpSellStart    = 0.0;     // SELL Start price: don't seed the first SELL until price >= this (0 = start at market)
input double InpBuyTarget    = 4550.0;  // BUY target price: book winners, keep top-N (panel Target 4550; 0 = off)
input double InpSellTarget   = 4300.0;  // SELL target price: book winners, keep top-N (panel Target 4300; 0 = off)
input int    InpKeepHedge    = 2;       // How many highest-profit positions to keep on Target
input bool   InpRepeatAfterTarget = false; // REP: after a Target book, re-seed the side automatically (repeat)
input bool   InpSlOn         = true;    // SL ON/OFF: enable the per-side money stop (panel "SL OFF" toggle)
input double InpSideSL       = 150.0;   // Per-side hard stop money: close a side if its floating loss <= -this (£). Gated by InpSlOn.
input bool   InpBasketOn     = false;   // BASK ON/OFF: enable basket-close (close ALL on combined float targets)

input group "ProS tier (price-anchored pro-scalp - the panel's ProS row shows a PRICE)"
input double InpBuyProSAnchor  = 0.0;   // BUY ProS price anchor (panel ProS Profit/T = a price, e.g. 4413.4; 0 = off, use money target)
input double InpSellProSAnchor = 0.0;   // SELL ProS price anchor (panel ProS = e.g. 4353.2; 0 = off)

input group "Scalp mode (high-frequency: keep N slots per side, re-seed after each win)"
input bool   InpScalpMode    = true;    // ON = keep InpScalpSlots positions open per side, tight spacing, re-seed after a win
input int    InpScalpSlots   = 3;       // Target concurrent positions PER SIDE to keep open (clamped by InpMaxLevels)
input double InpScalpGapPips = 8.0;     // Tight spacing between scalp entries, in PIPS (min price move before adding a slot)
input int    InpScalpMinSecs = 5;       // Throttle: minimum seconds between opens on a side (stops one tick opening all slots)

input group "Safety (defaults ON - the floor)"
input int    InpMaxLevels        = 8;     // Max open positions PER SIDE (0 = unlimited - DANGEROUS)
input double InpMaxFloatingLoss  = 800.0; // Close ALL if combined floating P/L <= -this (0 = off)
input double InpEquityStopPct    = 20.0;  // Close ALL + halt if equity drops this % below start (0 = off)
input double InpBasketTP         = 0.0;   // Close ALL when combined floating P/L >= this (0 = off)
input bool   InpCloseAllOnStop   = true;  // On a safety trip, flatten every position for this magic

input group "Directional gate (only trade grid in the direction of trend/bias)"
input bool   InpDirGate       = false;  // ON = only BUY when price>MA (uptrend), only SELL when price<MA (downtrend)
input int    InpDirMaPeriod   = 200;    // Slow MA period for the trend filter
input ENUM_TIMEFRAMES InpDirMaTF = PERIOD_H1; // Timeframe of the trend MA (higher TF = smoother bias)
input int    InpDirBufferPts  = 0;      // Deadband: price must be this many points past the MA to count (0 = none)

input group "JNS pullback entry (real JNS Scalper V22 mechanic)"
input bool   InpJnsPullback      = true; // Require a pullback before each add (JNS: don't chase, buy the dip)
input int    InpPullbackWaitSecs = 30;   // After a level is 'due', wait this many seconds before it can fill
input int    InpPullbackPoints   = 30;   // AND require price to retrace this many points back toward the extreme before filling
input int    InpJnsTriggerPoints = 100;  // Distance (points) price must first move from last entry to make the next level 'due'

input group "Engine"
input long   InpMagic        = 26023332;  // Magic number
input int    InpSlippage     = 30;         // Max deviation, points
input bool   InpStartRunning = true;       // Master START on attach
input bool   InpShowPanel    = true;       // Draw dashboard
input bool   InpEnableLog    = true;       // Log to Experts tab

//--- per-level parameters (Gap2/3/4/ProS). Level 1 uses base inputs.
//--- gap = entry spacing (POINTS); tp/lock = per-position MONEY targets (acct ccy).
//--- per-level params. gap=entry spacing (POINTS); tp/lock = per-position MONEY.
//--- prosAnchor: for the ProS tier only, an absolute PRICE the panel shows in Profit/T (0 = use money tp).
struct SLevel { int gap; double lot; double tp; double lock; bool on; double prosAnchor; };

//--- per-side runtime state (mirrors one panel column of controls)
struct SSide
  {
   bool   enabled;   // ST: side is started (master gate for this side)
   bool   paused;    // PU: temporarily paused (enabled stays, entries suppressed)
   double start;     // Start: price gate for the FIRST entry (0 = at market)
   double target;    // Target: basket price target (book winners keep top-N)
   bool   repeat;    // REP: re-seed automatically after a Target book
   bool   slOn;      // SL ON/OFF: per-side money stop enabled
   bool   baskOn;    // BASK ON/OFF: basket-close enabled for this side
   bool   helper;    // B+S / S+B: open an opposite-side helper leg on new entries
   SLevel lv[LVLS];  // Gap2..ProS
  };

//--- global runtime
struct SLive
  {
   double lot; int gap; double tp; double lock;  // base: gap=points, tp/lock=money
   int    prot; int trail;                   // management: prot=BE arm, trail=trailing step
   bool   running;                           // master
   SSide  buy;
   SSide  sell;
  };
SLive g;

//--- state
CTrade   m_trade;
string   m_sym;
double   m_point;
int      m_digits;
int      m_maHandle = INVALID_HANDLE;   // directional-gate trend MA handle
double   m_start_equity = 0.0;
double   m_start_balance = 0.0;                      // balance at session start (for Daily P/L)
bool     m_halted = false;
uint     m_last_draw = 0;

//--- session trade counters, per side (index 0 = BUY, 1 = SELL).
//--- scalp = profitable close, bad = losing close, total = every close.
int      m_scalp[2] = {0,0};
int      m_bad[2]   = {0,0};
int      m_total[2] = {0,0};
double   m_booked[2]= {0,0};                          // realized P/L booked this session, per side
datetime m_lastOpen[2] = {0,0};                       // last entry time per side (scalp throttle)
//--- JNS pullback-entry state, per side (0=BUY,1=SELL)
datetime m_dueTime[2] = {0,0};                        // when the next level became 'due' (0=not due)
double   m_dueExtreme[2] = {0,0};                     // best price reached since 'due' (low for BUY, high for SELL)

void Log(const string s){ if(InpEnableLog) Print("[GridHedge] ", s); }
double Ask(){ return SymbolInfoDouble(m_sym,SYMBOL_ASK); }
double Bid(){ return SymbolInfoDouble(m_sym,SYMBOL_BID); }
double Nz(double p){ return NormalizeDouble(p,m_digits); }

//--- pip <-> point conversion. JNS displays distances in PIPS (e.g. Gap 50.00);
//--- the engine works in POINTS. On 3/5-digit symbols 1 pip = 10 points,
//--- on 2/4-digit 1 pip = 10 points too; on 1-digit = 1. Use digit parity.
int    g_ppp = 10;                                   // points per pip (set in OnInit)
double PtsToPips(int pts){ return (double)pts / g_ppp; }
int    PipsToPts(double pips){ return (int)MathRound(pips * g_ppp); }
string PipStr(int pts){ return DoubleToString(PtsToPips(pts), 2); }   // panel display

#define PFX "GH_"
void PanelCreate(); void PanelUpdate(); void PanelDestroy();

//====================================================================
//  INIT
//====================================================================
void SeedSide(SSide &s, bool en, double startPx, double tgt, double prosAnchor)
  {
   s.enabled = en; s.paused=false; s.start=startPx; s.target=tgt;
   s.repeat = InpRepeatAfterTarget; s.slOn = InpSlOn; s.baskOn = InpBasketOn; s.helper = InpHelperOn;
   //--- Gap2/3/4 seeded identical from base (values don't matter here; panel edits live).
   for(int i=0;i<LVLS;i++)
     {
      s.lv[i].gap  = g.gap;
      s.lv[i].lot  = g.lot;
      s.lv[i].tp   = g.tp;
      s.lv[i].lock = g.lock;
      s.lv[i].on   = true;
      s.lv[i].prosAnchor = 0.0;      // only the ProS row uses this
     }
   //--- ProS (index LVLS-1): the price-anchored pro-scalp tier. The panel shows its
   //--- Profit/T as an absolute PRICE. If an anchor is set, ProS positions book when
   //--- price reaches the anchor (BUY: bid>=anchor; SELL: ask<=anchor). If 0, ProS
   //--- falls back to a relaxed money target so it still behaves like a runner slot.
   s.lv[LVLS-1].prosAnchor = prosAnchor;
   if(prosAnchor<=0) s.lv[LVLS-1].tp = g.tp * 5.0;   // relaxed money target when no price anchor
   s.lv[LVLS-1].lock = g.lock;
   s.lv[LVLS-1].lot  = g.lot * 2.0;                  // ProS heavier slot (panel ProS Lot)
  }

int OnInit()
  {
   m_sym=_Symbol; m_point=SymbolInfoDouble(m_sym,SYMBOL_POINT);
   m_digits=(int)SymbolInfoInteger(m_sym,SYMBOL_DIGITS);
   //--- 1 pip = 10 points on 3/5-digit (and gold's typical 2-digit) quotes; 1 on whole-point
   g_ppp = (m_digits==3 || m_digits==5 || m_digits==2) ? 10 : 1;
   if(InpLot<=0||InpGapPoints<=0||InpTpMoney<=0)
     { Print("[GridHedge] bad inputs (lot/gap/profit must be > 0)"); return INIT_PARAMETERS_INCORRECT; }
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("[GridHedge] WARNING: not a hedging account - buy/sell will net off.");

   g.lot=InpLot; g.gap=InpGapPoints; g.tp=InpTpMoney; g.lock=InpLockMoney;
   g.prot=InpProtPoints; g.trail=InpTrailStepPoints; g.running=InpStartRunning;
   SeedSide(g.buy,  InpTradeBuy,  InpBuyStart,  InpBuyTarget,  InpBuyProSAnchor);
   SeedSide(g.sell, InpTradeSell, InpSellStart, InpSellTarget, InpSellProSAnchor);

   //--- directional-gate trend MA (created once; released in OnDeinit)
   if(InpDirGate)
     {
      m_maHandle = iMA(m_sym, InpDirMaTF, InpDirMaPeriod, 0, MODE_SMA, PRICE_CLOSE);
      if(m_maHandle==INVALID_HANDLE) Print("[GridHedge] WARNING: dir-gate MA handle failed; gate disabled");
     }

   m_trade.SetExpertMagicNumber(InpMagic);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFillingBySymbol(m_sym);
   m_start_equity=AccountInfoDouble(ACCOUNT_EQUITY);
   m_start_balance=AccountInfoDouble(ACCOUNT_BALANCE); m_halted=false;

   //--- restore a saved panel position (if the user moved it before)
   long sx=0, sy=0;
   if(GlobalVariableCheck(PFX"ox")) g_ox=(int)GlobalVariableGet(PFX"ox");
   if(GlobalVariableCheck(PFX"oy")) g_oy=(int)GlobalVariableGet(PFX"oy");
   ChartSetInteger(0,CHART_EVENT_MOUSE_MOVE,true);   // needed for panel dragging

   if(InpShowPanel) PanelCreate();
   ChartRedraw(0);
   Log(StringFormat("init v3.3 lot=%.2f gap=%d profit=%.2f lock=%.2f prot=%d trail=%d run=%s | helper=%s slOn=%s baskOn=%s repeat=%s | scalp=%s slots=%d sgap=%.1fpip throttle=%ds",
        g.lot,g.gap,g.tp,g.lock,g.prot,g.trail,g.running?"on":"off",
        InpHelperOn?"on":"off",InpSlOn?"on":"off",InpBasketOn?"on":"off",InpRepeatAfterTarget?"on":"off",
        InpScalpMode?"ON":"off",InpScalpSlots,InpScalpGapPips,InpScalpMinSecs));
   return INIT_SUCCEEDED;
  }
void OnDeinit(const int r){ if(m_maHandle!=INVALID_HANDLE) IndicatorRelease(m_maHandle); PanelDestroy(); ChartRedraw(0); }

//--- Directional gate: is a new entry on 'side' allowed by the trend filter?
//--- BUY allowed only when price is above the MA (+buffer); SELL only when below.
//--- Returns true when the gate is OFF or the MA can't be read (fail-open).
bool DirGateAllows(const ENUM_POSITION_TYPE side)
  {
   if(!InpDirGate || m_maHandle==INVALID_HANDLE) return true;
   double ma[]; if(CopyBuffer(m_maHandle,0,0,1,ma)<1) return true;   // fail-open if not ready
   double px = (side==POSITION_TYPE_BUY)? Ask() : Bid();
   double buf = InpDirBufferPts*m_point;
   if(side==POSITION_TYPE_BUY)  return (px >= ma[0]+buf);
   else                         return (px <= ma[0]-buf);
  }

//--- Session tally: every time one of OUR positions is (partly) closed a deal
//--- with entry==OUT lands in history. Classify it profit vs loss per side.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &req,
                        const MqlTradeResult &res)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   ulong ticket=trans.deal;
   if(ticket==0 || !HistoryDealSelect(ticket)) return;
   if(HistoryDealGetInteger(ticket,DEAL_MAGIC)!=InpMagic) return;
   if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=m_sym)    return;
   if(HistoryDealGetInteger(ticket,DEAL_ENTRY)!=DEAL_ENTRY_OUT) return;   // only closing deals

   //--- a closing BUY position produces a SELL deal, and vice-versa
   long dt = HistoryDealGetInteger(ticket,DEAL_TYPE);
   int  si = (dt==DEAL_TYPE_SELL) ? 0 : 1;   // sell-out closes a BUY(0); buy-out closes a SELL(1)
   double pl = HistoryDealGetDouble(ticket,DEAL_PROFIT)
             + HistoryDealGetDouble(ticket,DEAL_SWAP)
             + HistoryDealGetDouble(ticket,DEAL_COMMISSION);
   m_total[si]++;
   m_booked[si]+=pl;
   if(pl>=0) m_scalp[si]++; else m_bad[si]++;
  }

//====================================================================
//  POSITION HELPERS
//====================================================================
int SideCount(const ENUM_POSITION_TYPE side)
  {
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==side)n++; }
   return n;
  }
double LastEntryPrice(const ENUM_POSITION_TYPE side,bool &found)
  {
   found=false; double res=0; datetime nw=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=side)continue;
       datetime tt=(datetime)PositionGetInteger(POSITION_TIME);
       if(tt>=nw){nw=tt;res=PositionGetDouble(POSITION_PRICE_OPEN);found=true;} }
   return res;
  }
double SideFloating(const ENUM_POSITION_TYPE side)
  {
   double tot=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=side)continue;
       tot+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP); }
   return tot;
  }
double BasketFloating(){ return SideFloating(POSITION_TYPE_BUY)+SideFloating(POSITION_TYPE_SELL); }

//--- which level params apply to the Nth open position on a side (clamped)
void LevelFor(const ENUM_POSITION_TYPE side,const int count,SLevel &out)
  {
   SSide s = (side==POSITION_TYPE_BUY)? g.buy : g.sell;
   //--- position 1 uses base; positions 2.. map to lv[0..]; clamp to ProS
   if(count<=1){ out.gap=g.gap; out.lot=g.lot; out.tp=g.tp; out.lock=g.lock; out.on=true; return; }
   int idx = count-2; if(idx>=LVLS) idx=LVLS-1;
   out = s.lv[idx];
  }

//--- parse a position's level number from its "P<n>" comment (1 if unknown)
int PosLevel(const string cmt)
  {
   if(StringLen(cmt)>=2 && StringGetCharacter(cmt,0)=='P')
     { int v=(int)StringToInteger(StringSubstr(cmt,1)); if(v>0) return v; }
   return 1;
  }

//--- per-position money targets (tp, lock) for a position at 'level' on 'side'.
//--- level 1 -> base g.tp/g.lock; level 2.. -> that side's lv[level-2] (clamp ProS)
void MoneyTargetsFor(const ENUM_POSITION_TYPE side,const int level,double &tp_out,double &lock_out)
  {
   if(level<=1){ tp_out=g.tp; lock_out=g.lock; return; }
   SSide s = (side==POSITION_TYPE_BUY)? g.buy : g.sell;
   int idx=level-2; if(idx>=LVLS) idx=LVLS-1;
   tp_out=s.lv[idx].tp; lock_out=s.lv[idx].lock;
  }

//--- ProS price anchor that applies to a position at 'level' on 'side' (0 = none).
//--- Only the ProS tier (mapped level index LVLS-1) carries an anchor.
double ProSAnchorFor(const ENUM_POSITION_TYPE side,const int level)
  {
   if(level<=1) return 0.0;
   SSide s = (side==POSITION_TYPE_BUY)? g.buy : g.sell;
   int idx=level-2; if(idx>=LVLS) idx=LVLS-1;
   return s.lv[idx].prosAnchor;
  }

//====================================================================
//  ORDERS
//====================================================================
bool g_inHelper=false;   // reentrancy guard: a helper leg must not open its own helper
void OpenHelper(const ENUM_POSITION_TYPE justOpened);   // fwd decl

bool OpenLevel(const ENUM_POSITION_TYPE side,const int level,const double lot)
  {
   string cmt=StringFormat("P%d",level); bool ok;
   if(side==POSITION_TYPE_BUY) ok=m_trade.Buy(lot,m_sym,0,0,0,cmt);
   else                        ok=m_trade.Sell(lot,m_sym,0,0,0,cmt);
   if(ok) m_lastOpen[side==POSITION_TYPE_BUY?0:1]=TimeCurrent();   // scalp throttle stamp
   Log(StringFormat("%s %s lot=%.2f: %s rc=%u",side==POSITION_TYPE_BUY?"BUY":"SELL",cmt,lot,
        ok?"opened":"FAILED",m_trade.ResultRetcode()));
   //--- B+S / S+B helper: fire an opposite leg if this side's helper is on (guarded)
   if(ok && !g_inHelper)
     {
      bool wantHelper = (side==POSITION_TYPE_BUY)? g.buy.helper : g.sell.helper;
      if(wantHelper){ g_inHelper=true; OpenHelper(side); g_inHelper=false; }
     }
   return ok;
  }
void CloseSide(const ENUM_POSITION_TYPE side,const string reason)
  {
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=side)continue;
       if(m_trade.PositionClose(t))n++; }
   if(n>0) Log(StringFormat("close %s x%d: %s",side==POSITION_TYPE_BUY?"BUY":"SELL",n,reason));
  }
void CloseAll(const string reason){ CloseSide(POSITION_TYPE_BUY,reason); CloseSide(POSITION_TYPE_SELL,reason); Log("CLOSE ALL: "+reason); }

//--- RE (Restart from market): flatten the side and immediately re-seed a fresh
//--- level-1 entry at the current market. Clears pause and any pullback arming.
void RestartSide(const ENUM_POSITION_TYPE side)
  {
   int si=(side==POSITION_TYPE_BUY?0:1);
   CloseSide(side,"RE restart");
   m_dueTime[si]=0; m_repeatArm[si]=false;
   if(side==POSITION_TYPE_BUY) g.buy.paused=false; else g.sell.paused=false;
   OpenLevel(side,1,g.lot);
   Log(StringFormat("%s RE: restarted from market",side==POSITION_TYPE_BUY?"BUY":"SELL"));
  }

//--- Target: book profitable positions on a side but keep top-N by profit
void BookPositivesKeepTop(const ENUM_POSITION_TYPE side,const int keep,const string reason)
  {
   ulong tk[]; double pf[]; int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=side)continue;
       double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
       if(p<=0)continue;
       ArrayResize(tk,n+1);ArrayResize(pf,n+1);tk[n]=t;pf[n]=p;n++; }
   if(n<=keep)return;
   for(int a=0;a<n-1;a++)for(int b=a+1;b<n;b++)
      if(pf[b]>pf[a]){double x=pf[a];pf[a]=pf[b];pf[b]=x;ulong y=tk[a];tk[a]=tk[b];tk[b]=y;}
   int closed=0; for(int i=keep;i<n;i++) if(m_trade.PositionClose(tk[i]))closed++;
   if(closed>0) Log(StringFormat("%s TARGET %s: booked %d, kept top %d",side==POSITION_TYPE_BUY?"BUY":"SELL",reason,closed,keep));
  }

//====================================================================
//  MANAGEMENT: profit-close, lock-book, Prot(BE) + B+S(trail)
//====================================================================
void ManagePositions()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i); if(t==0)continue;
      if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool lng=(type==POSITION_TYPE_BUY);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double cur= lng?Bid():Ask();
      double ppt=(lng?(cur-entry):(entry-cur))/m_point;   // still used by Prot/B+S (distance)
      double pmoney=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP); // account ccy

      //--- per-position targets from THIS position's own level (via P<n> comment)
      int    lvl = PosLevel(PositionGetString(POSITION_COMMENT));
      double tpM, lockM; MoneyTargetsFor(type, lvl, tpM, lockM);

      //--- ProS PRICE ANCHOR: if this position is a ProS-tier leg and its side has a
      //--- price anchor, book it when price reaches the anchor (BUY: bid>=anchor;
      //--- SELL: ask<=anchor). This is the panel's ProS Profit/T-as-a-price behavior.
      double anchor = ProSAnchorFor(type, lvl);
      if(anchor>0)
        {
         bool hit = lng ? (Bid()>=anchor) : (Ask()<=anchor);
         if(hit){ if(m_trade.PositionClose(t))Log(StringFormat("#%I64u ProS ANCHOR %.*f hit",t,m_digits,anchor)); continue; }
        }

      //--- PROFIT CLOSE: book this position when its MONEY profit reaches its
      //--- level's target (£), regardless of pip distance.
      if(tpM>0 && pmoney>=tpM){ if(m_trade.PositionClose(t))Log(StringFormat("#%I64u P%d PROFIT %.2f>=%.2f",t,lvl,pmoney,tpM)); continue; }
      //--- lock & book: level's own larger money target for a runner (if set above its Profit)
      if(lockM>0 && lockM!=tpM && pmoney>=lockM){ if(m_trade.PositionClose(t))Log(StringFormat("#%I64u P%d LOCK %.2f>=%.2f",t,lvl,pmoney,lockM)); continue; }

      //--- Prot: arm break-even; trailing step trails the stop once armed
      if(g.prot>0 && ppt>=g.prot)
        {
         double be = lng? entry+InpBeOffsetPoints*m_point : entry-InpBeOffsetPoints*m_point;
         double want = be;
         if(g.trail>0)  // trail: keep stop g.trail points behind current, but never worse than BE
           {
            double trail = lng? cur-g.trail*m_point : cur+g.trail*m_point;
            want = lng? MathMax(be,trail) : MathMin(be,trail);
           }
         want=Nz(want);
         bool need = lng? (sl<want-m_point) : (sl==0.0 || sl>want+m_point);
         if(need && m_trade.PositionModify(t,want,0.0))
            Log(StringFormat("#%I64u Prot/trail SL->%.*f (+%.0f)",t,m_digits,want,ppt));
        }
     }
  }

//====================================================================
//  SAFETY
//====================================================================
bool SafetyCheck()
  {
   if(m_halted)return true;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY), bk=BasketFloating();
   //--- BASK ON/OFF (either side enabling basket-close arms the combined basket TP)
   bool baskOn = g.buy.baskOn || g.sell.baskOn;
   if(baskOn && InpBasketTP>0 && bk>=InpBasketTP){ CloseAll(StringFormat("basket TP %.2f",bk)); return false; }
   if(InpMaxFloatingLoss>0 && bk<=-InpMaxFloatingLoss)
     { if(InpCloseAllOnStop)CloseAll(StringFormat("MAX FLOAT LOSS %.2f",bk)); m_halted=true; g.running=false;
       Log("HALTED float-loss. START to resume."); return true; }
   if(InpEquityStopPct>0 && m_start_equity>0)
     { double dd=(m_start_equity-eq)/m_start_equity*100.0;
       if(dd>=InpEquityStopPct){ if(InpCloseAllOnStop)CloseAll(StringFormat("EQ STOP %.2f%%",dd)); m_halted=true; g.running=false;
         Log("HALTED equity. START to resume."); return true; } }
   return false;
  }

//--- Per-side money stop (gated by SL ON/OFF) + Target price booking (+REP repeat).
//--- m_repeatArm[si] latches TRUE right after a Target book so the next ManageSide
//--- pass re-seeds the side from market when REP is on.
bool m_repeatArm[2] = {false,false};
void BasketChecks()
  {
   //--- SL ON/OFF is per side now (panel toggle). InpSideSL is the money level.
   if(InpSideSL>0)
     { if(g.buy.slOn  && SideCount(POSITION_TYPE_BUY)>0  && SideFloating(POSITION_TYPE_BUY) <=-InpSideSL) CloseSide(POSITION_TYPE_BUY,"side SL");
       if(g.sell.slOn && SideCount(POSITION_TYPE_SELL)>0 && SideFloating(POSITION_TYPE_SELL)<=-InpSideSL) CloseSide(POSITION_TYPE_SELL,"side SL"); }

   //--- Target: book winners keep top-N. If REP is on, arm a re-seed after booking.
   if(g.buy.target>0  && SideCount(POSITION_TYPE_BUY) >InpKeepHedge && Bid()>=g.buy.target)
     { BookPositivesKeepTop(POSITION_TYPE_BUY, InpKeepHedge, StringFormat("bid>=%.*f",m_digits,g.buy.target));
       if(g.buy.repeat) m_repeatArm[0]=true; }
   if(g.sell.target>0 && SideCount(POSITION_TYPE_SELL)>InpKeepHedge && Ask()<=g.sell.target)
     { BookPositivesKeepTop(POSITION_TYPE_SELL,InpKeepHedge, StringFormat("ask<=%.*f",m_digits,g.sell.target));
       if(g.sell.repeat) m_repeatArm[1]=true; }
  }

//====================================================================
//  GRID (per-level gap/lot)
//====================================================================
//--- B+S / S+B helper: when a side opens a new leg and its helper toggle is on,
//--- open one small opposite-side leg (the JNS "Buy+Sell helper"). Uses base lot.
void OpenHelper(const ENUM_POSITION_TYPE justOpened)
  {
   ENUM_POSITION_TYPE opp = (justOpened==POSITION_TYPE_BUY)? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   if(InpMaxLevels>0 && SideCount(opp)>=InpMaxLevels) return;
   if(!DirGateAllows(opp)) return;   // don't open a counter-trend helper when the gate is on
   OpenLevel(opp, 1, g.lot);   // helper leg tagged as level 1
   Log(StringFormat("%s helper opened %s leg", justOpened==POSITION_TYPE_BUY?"B+S":"S+B",
        opp==POSITION_TYPE_BUY?"BUY":"SELL"));
  }

//--- Start-price gate: the side's first entry waits until price is at/through Start.
//--- BUY starts when Ask<=Start; SELL starts when Bid>=Start. 0 = start at market.
bool StartGateOpen(const ENUM_POSITION_TYPE side,const SSide &s)
  {
   if(s.start<=0) return true;
   return (side==POSITION_TYPE_BUY) ? (Ask()<=s.start) : (Bid()>=s.start);
  }

void ManageSide(const ENUM_POSITION_TYPE side,const SSide &s)
  {
   if(!s.enabled || s.paused) return;                  // ST off or PU paused => no entries
   int si=(side==POSITION_TYPE_BUY?0:1);
   int count=SideCount(side);
   if(InpMaxLevels>0 && count>=InpMaxLevels) return;   // hard safety cap always wins
   //--- Directional gate: block NEW entries on the counter-trend side. Existing
   //--- positions are still managed/closed by ManagePositions; we only stop adding.
   if(!DirGateAllows(side)) return;
   //--- Start-price gate blocks only the FIRST seed (once a side has legs it ladders freely)
   if(count==0 && !StartGateOpen(side,s)) return;
   //--- REP: after a Target book, re-seed this side from market on the next opportunity
   if(m_repeatArm[si] && count==0){ OpenLevel(side,1,g.lot); m_repeatArm[si]=false; return; }   // OpenLevel auto-fires helper

   //================= SCALP MODE (high-frequency, Option A) =================
   //--- Keep up to InpScalpSlots positions open per side (clamped by the max-
   //--- levels floor). Space each new slot by a TIGHT scalp gap, and throttle
   //--- opens by InpScalpMinSecs so a single volatile tick can't fire the whole
   //--- stack at once. When a winner closes, count drops and the next tick
   //--- re-seeds a fresh slot automatically -> the churn that books many wins.
   if(InpScalpMode)
     {
      int slots=InpScalpSlots;
      if(InpMaxLevels>0 && slots>InpMaxLevels) slots=InpMaxLevels;
      if(slots<1) slots=1;
      if(count>=slots) return;                          // side already full

      //--- throttle: enforce a minimum interval between opens on this side
      if(InpScalpMinSecs>0 && m_lastOpen[si]>0 &&
         (TimeCurrent()-m_lastOpen[si]) < InpScalpMinSecs) return;

      if(count==0){ OpenLevel(side,1,g.lot); m_dueTime[si]=0; return; }  // first slot: seed at market

      bool found=false; double last=LastEntryPrice(side,found); if(!found)return;
      double px = (side==POSITION_TYPE_BUY)? Ask() : Bid();

      //--- CLASSIC scalp (no pullback): tight gap from last entry, fire immediately.
      if(!InpJnsPullback)
        {
         double sgap=PipsToPts(InpScalpGapPips)*m_point;
         bool add=false;
         if(side==POSITION_TYPE_BUY  && Ask()<=last-sgap) add=true;
         if(side==POSITION_TYPE_SELL && Bid()>=last+sgap) add=true;
         if(add){ SLevel nx; LevelFor(side,count+1,nx); OpenLevel(side,count+1, nx.lot>0?nx.lot:g.lot); }
         return;
        }

      //================= JNS PULLBACK ENTRY =================
      //--- Step 1: the next level becomes 'due' only after price has moved
      //--- InpJnsTriggerPoints away from the last entry (the grid step).
      double trig = InpJnsTriggerPoints*m_point;
      bool moved = (side==POSITION_TYPE_BUY)? (px <= last-trig) : (px >= last+trig);

      if(m_dueTime[si]==0)
        {
         if(moved){ m_dueTime[si]=TimeCurrent(); m_dueExtreme[si]=px; }  // arm; start tracking the extreme
         return;
        }

      //--- Step 2: while 'due', track the extreme (lowest for BUY, highest for SELL).
      if(side==POSITION_TYPE_BUY){ if(px<m_dueExtreme[si]) m_dueExtreme[si]=px; }
      else                       { if(px>m_dueExtreme[si]) m_dueExtreme[si]=px; }

      //--- Step 3: fire only after BOTH the wait AND a pullback from the extreme.
      bool waited   = (TimeCurrent()-m_dueTime[si]) >= InpPullbackWaitSecs;
      double pbk    = InpPullbackPoints*m_point;
      bool pulled   = (side==POSITION_TYPE_BUY)? (px >= m_dueExtreme[si]+pbk)   // bounced up off the dip
                                               : (px <= m_dueExtreme[si]-pbk);  // pulled back down off the spike
      if(waited && pulled)
        {
         SLevel nx; LevelFor(side,count+1,nx);
         OpenLevel(side,count+1, nx.lot>0?nx.lot:g.lot);
         m_dueTime[si]=0;   // reset; next level must re-arm
        }
      return;
     }

   //================= CLASSIC DCA MODE (wide gap, one leg per move) =========
   if(count==0){ OpenLevel(side,1,g.lot); return; }
   SLevel nx; LevelFor(side,count+1,nx);
   if(!nx.on) return;
   bool found=false; double last=LastEntryPrice(side,found); if(!found)return;
   double gap=nx.gap*m_point;
   bool add=false;
   if(side==POSITION_TYPE_BUY  && Ask()<=last-gap) add=true;
   if(side==POSITION_TYPE_SELL && Bid()>=last+gap) add=true;
   if(add) OpenLevel(side,count+1,nx.lot);
  }

void OnTick()
  {
   if(SafetyCheck()){ PanelUpdate(); return; }
   BasketChecks();
   ManagePositions();
   if(g.running)
     { ManageSide(POSITION_TYPE_BUY,  g.buy);
       ManageSide(POSITION_TYPE_SELL, g.sell); }
   uint now=GetTickCount(); if(now-m_last_draw>=250){ m_last_draw=now; PanelUpdate(); }
  }

//====================================================================
//  DASHBOARD (v3) - full JNS-style layout
//  Control meanings are INTERPRETED (see header). Buttons per side:
//   ST=enable entries  PU=pause entries  CL=close side
//   SY=resync panel     REP=log side report
//  Fields: Lot / Prot / Lock / B+S ; basket: Start(disp) / Target / SL
//  Grid table: Gap2/3/4/ProS x (Gap | Lot | Profit | Lock | ON)
//====================================================================
//--- Panel ORIGIN is now a live variable so the whole dashboard can be
//--- dragged. Every build function reads GH_X/GH_Y, so shifting these two
//--- globals moves everything together. Persisted to a chart-global so it
//--- survives recompiles/re-attach.
int  g_ox = 8;         // panel left edge (movable)
int  g_oy = 22;        // panel top edge  (movable)
#define GH_X    g_ox
#define GH_Y    g_oy
#define GH_W    440    // side-panel width (wide enough for the larger font + spacing)
#define GH_PAD  14     // inner left/right padding inside a panel
#define GH_GAP  16     // gap between the two side panels
#define GH_FS   10     // base font size (bumped)
#define GH_RH   28     // row pitch (field rows)
#define GH_LRH  26     // per-level table row pitch
#define DRAGH   24     // drag-handle bar height

bool     g_min  = false;   // dashboard minimized state
//--- drag state
bool     g_drag = false;   // currently dragging the panel
int      g_dragDX = 0, g_dragDY = 0;   // cursor offset from panel origin at grab

color CBUYBG=C'12,28,54', CSELLBG=C'54,14,18', CHBUY=C'46,120,220', CHSELL=C'210,60,66';
color CFLD=C'22,26,34', CTXT=C'230,232,238', CMUTE=C'150,160,175';
color CON=C'0,150,70', COFF=C'120,40,44', CBTN=C'40,52,70', CGOLD=C'214,175,55';

void oRect(string n,int x,int y,int w,int h,color bg,color bd)
  { if(ObjectFind(0,n)<0)ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
    ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
    ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
    ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
    ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
    ObjectSetInteger(0,n,OBJPROP_COLOR,bd);ObjectSetInteger(0,n,OBJPROP_BACK,false);
    ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,n,OBJPROP_HIDDEN,true); }
void oLbl(string n,int x,int y,string t,color c,int fs=GH_FS,bool b=false)
  { if(ObjectFind(0,n)<0)ObjectCreate(0,n,OBJ_LABEL,0,0,0);
    ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
    ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
    ObjectSetString(0,n,OBJPROP_TEXT,t);ObjectSetString(0,n,OBJPROP_FONT,b?"Arial Bold":"Arial");
    ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);ObjectSetInteger(0,n,OBJPROP_COLOR,c);
    ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,n,OBJPROP_HIDDEN,true); }
void oEdit(string n,int x,int y,int w,int h,string t)
  { if(ObjectFind(0,n)<0)ObjectCreate(0,n,OBJ_EDIT,0,0,0);
    ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
    ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
    ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
    ObjectSetString(0,n,OBJPROP_TEXT,t);ObjectSetInteger(0,n,OBJPROP_FONTSIZE,GH_FS);
    ObjectSetInteger(0,n,OBJPROP_COLOR,CTXT);ObjectSetInteger(0,n,OBJPROP_BGCOLOR,CFLD);
    ObjectSetInteger(0,n,OBJPROP_ALIGN,ALIGN_CENTER);ObjectSetInteger(0,n,OBJPROP_READONLY,false);
    ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,n,OBJPROP_HIDDEN,true); }
void oBtn(string n,int x,int y,int w,int h,string t,color bg)
  { if(ObjectFind(0,n)<0)ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
    ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
    ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
    ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
    ObjectSetString(0,n,OBJPROP_TEXT,t);ObjectSetString(0,n,OBJPROP_FONT,"Arial Bold");
    ObjectSetInteger(0,n,OBJPROP_FONTSIZE,GH_FS);ObjectSetInteger(0,n,OBJPROP_COLOR,CTXT);
    ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,CGOLD);
    ObjectSetInteger(0,n,OBJPROP_STATE,false);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
    ObjectSetInteger(0,n,OBJPROP_HIDDEN,true); }

string LvName(int i){ return (i==0?"Gap2":i==1?"Gap3":i==2?"Gap4":"ProS"); }

//--- short broker/company label for the header (e.g. "Vantage")
string BrokerName()
  {
   string co = AccountInfoString(ACCOUNT_COMPANY);
   if(co=="") co = AccountInfoString(ACCOUNT_SERVER);
   //--- keep it short: first word only (e.g. "Vantage Global ..." -> "Vantage")
   int sp = StringFind(co," ");
   if(sp>0) co = StringSubstr(co,0,sp);
   //--- strip common suffixes/markers
   StringReplace(co,"-Demo","");
   if(co=="") co="Broker";
   return co;
  }

//--- "BUY - Vantage | Opened Buy = 30"  (side = "BUY" or "SELL")
string HeaderText(const string side)
  {
   ENUM_POSITION_TYPE pt = (side=="BUY")? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   int n = SideCount(pt);
   string word = (side=="BUY")? "Buy" : "Sell";
   return StringFormat("%s - %s | Opened %s = %d", side, BrokerName(), word, n);
  }

//--- build one side; k = "b" or "s"; returns bottom Y used.
//--- All columns are computed from GH_W with fixed gutters so NOTHING
//--- overflows the panel (usable inner width = GH_W - 2*GH_PAD = 316px).
int BuildSide(int bx,string side,string k,color hc,color bg,const SSide &s)
  {
   const int L = bx + GH_PAD;              // inner left
   const int R = bx + GH_W - GH_PAD;       // inner right
   int y = GH_Y + DRAGH + 2;               // sit below the drag handle
   //--- header + btnrow + togglerow + 3 field rows + table(header+rows) + 3 status rows
   int H = 26 + (GH_RH+2) + (GH_RH+4) + GH_RH*2 + (GH_RH+6) + 20 + (LVLS)*GH_LRH + 10 + 20 + GH_RH + (GH_RH+2) + 12;
   oRect(PFX+k+"bg",bx,y,GH_W,H,bg,hc);
   //--- header: "<SIDE> - <broker> | Opened <Side> = <n>" (JNS style, live count)
   oLbl(PFX+k+"hd",L,y+5,HeaderText(side),hc,GH_FS+1,true); y+=26;

   const int IW = GH_W - 2*GH_PAD;         // usable inner width (derived, not hardcoded)

   //--- button row 1: ST PU CL SY RE REP  (6 control buttons, matching the panel)
   int bgap=6, bw=(IW - 5*bgap)/6;         // equal-width buttons that fit exactly
   {
    string nm[6]={"ST","PU","CL","SY","RE","REP"}; string tx[6]={"ST","PU","CL","SY","RE","REP"};
    for(int bidx=0;bidx<6;bidx++)
      {
       int bxp = L + bidx*(bw+bgap);
       color bc = CBTN;
       if(bidx==0) bc = (s.enabled && !s.paused)?CON:CBTN;   // ST lit when running
       else if(bidx==1) bc = s.paused?CGOLD:CBTN;            // PU lit when paused
       else if(bidx==2) bc = COFF;                            // CL red
       else if(bidx==5) bc = s.repeat?CON:CBTN;               // REP lit when on
       oBtn(PFX+k+nm[bidx], bxp, y, bw,22, tx[bidx], bc);
      }
   }
   y += GH_RH+2;

   //--- toggle row: SL ON/OFF | BASK ON/OFF | B+S(S+B) helper ON/OFF  (3 wide toggles)
   {
    int tgap=7, tw=(IW - 2*tgap)/3;
    string bsLbl = (k=="b") ? "B+S" : "S+B";
    oBtn(PFX+k+"tglSL",  L,               y, tw,20, s.slOn ? "SL ON":"SL OFF",     s.slOn?CON:COFF);
    oBtn(PFX+k+"tglBK",  L+tw+tgap,        y, tw,20, s.baskOn?"BASK ON":"BASK OFF", s.baskOn?CON:COFF);
    oBtn(PFX+k+"tglBS",  L+2*(tw+tgap),    y, tw,20, s.helper?bsLbl+" ON":bsLbl+" OFF", s.helper?CON:COFF);
   }
   y += GH_RH+4;

   //--- field rows: 3 columns. Each column = a label then a wide edit box,
   //--- with a real gap so text never collides. lw = label width, ew = edit.
   int colw=IW/3, lw=42, ew=colw-lw-6, eh=20;
   int fc0=L, fc1=L+colw, fc2=L+2*colw;
   //--- Row 1: Lot | Profit(money) | Lock(money)
   oLbl (PFX+k+"lLot",fc0,   y+4,"Lot", CMUTE); oEdit(PFX+k+"eLot",fc0+lw, y, ew,eh, DoubleToString(g.lot,2));
   oLbl (PFX+k+"lPrf",fc1,   y+4,"Prof",CMUTE); oEdit(PFX+k+"ePrf",fc1+lw, y, ew,eh, DoubleToString(g.tp,2));
   oLbl (PFX+k+"lLk", fc2,   y+4,"Lock",CMUTE); oEdit(PFX+k+"eLk", fc2+lw, y, ew,eh, DoubleToString(g.lock,2));
   y += GH_RH;
   //--- Row 2: Prot(pips) | Trail(pips) | Target(price)
   oLbl (PFX+k+"lPrt",fc0,   y+4,"Prot", CMUTE); oEdit(PFX+k+"ePrt",fc0+lw, y, ew,eh, PipStr(g.prot));
   oLbl (PFX+k+"lTr", fc1,   y+4,"Trail",CMUTE); oEdit(PFX+k+"eTr", fc1+lw, y, ew,eh, PipStr(g.trail));
   oLbl (PFX+k+"lTgt",fc2,   y+4,"Tgt",  CMUTE); oEdit(PFX+k+"eTgt",fc2+lw, y, ew,eh, DoubleToString(s.target,2));
   y += GH_RH;
   //--- Row 3: Start(price) | (spacer)  - the panel's per-side Start field
   oLbl (PFX+k+"lSt", fc0,   y+4,"Start",CMUTE); oEdit(PFX+k+"eSt", fc0+lw, y, ew,eh, DoubleToString(s.start,2));
   y += GH_RH+6;

   //--- grid table: 6 columns derived from the inner width with gutters so
   //--- Lv | Gap | Lot | Prof | Lock | ON always span exactly IW.
   int gg=6;
   int wLv=40, wOn=52;
   int wData=(IW - wLv - wOn - 5*gg)/4;    // Gap/Lot/Prof/Lock share the rest
   int xLv=L, xGap=xLv+wLv+gg, xLot=xGap+wData+gg, xProf=xLot+wData+gg, xLock=xProf+wData+gg, xOn=xLock+wData+gg;
   oLbl(PFX+k+"tv",xLv,  y,"Lv",  CMUTE); oLbl(PFX+k+"tg",xGap, y,"Gap", CMUTE);
   oLbl(PFX+k+"tl",xLot, y,"Lot", CMUTE); oLbl(PFX+k+"tp",xProf,y,"Prof",CMUTE);
   oLbl(PFX+k+"tk",xLock,y,"Lock",CMUTE); oLbl(PFX+k+"to",xOn,  y,"ON",  CMUTE);
   y += 20;
   for(int i=0;i<LVLS;i++)
     {
      int ry=y+i*GH_LRH;
      bool isPros = (i==LVLS-1);
      //--- ProS Profit/T column holds a PRICE anchor (panel behaviour); others hold money tp.
      string profTxt = (isPros && s.lv[i].prosAnchor>0) ? DoubleToString(s.lv[i].prosAnchor,m_digits)
                                                        : DoubleToString(s.lv[i].tp,2);
      oLbl (PFX+k+"n"+(string)i, xLv,  ry+3, LvName(i), CTXT);
      oEdit(PFX+k+"g"+(string)i, xGap, ry, wData,18, PipStr(s.lv[i].gap));
      oEdit(PFX+k+"l"+(string)i, xLot, ry, wData,18, DoubleToString(s.lv[i].lot,2));
      oEdit(PFX+k+"p"+(string)i, xProf,ry, wData,18, profTxt);
      oEdit(PFX+k+"k"+(string)i, xLock,ry, wData,18,DoubleToString(s.lv[i].lock,2));
      oBtn (PFX+k+"o"+(string)i, xOn,  ry, wOn,18,  s.lv[i].on?"ON":"OFF", s.lv[i].on?CON:COFF);
     }
   y += LVLS*GH_LRH + 10;

   //--- live status rows
   oLbl(PFX+k+"sLvl",L,y,"Levels: 0",CTXT); y+=20;
   oLbl(PFX+k+"sPL", L,y,"P/L: 0.00",CTXT); y+=GH_RH;
   oBtn(PFX+k+"clsAll",L,y,IW,24,"CLOSE "+side,COFF); y+=GH_RH+2;
   return y;
  }

//--- monospace label helper for the log grid (fixed-width columns line up)
void oMono(string n,int x,int y,string t,color c,int fs=GH_FS+1)
  {
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetString (0,n,OBJPROP_TEXT,t);
   ObjectSetString (0,n,OBJPROP_FONT,"Consolas"); ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }

#define PT_ROWS 8              // trade rows shown per side in the bottom log
//--- 7-column monospace header for the per-side trade log
string PtHeader(){ return StringFormat("%-4s %-5s %-6s %-6s %-6s %-8s %-4s",
                        "Row","Lot","Prof","Book","State","P&L","Safe"); }

//--- Bottom log: an account line, then BUY (left) and SELL (right) trade
//--- tables with a per-side summary line under each. Monospace so columns
//--- align. Guessed columns (Book, State WAIT/STUCK, Safe) are best-effort.
void BuildPosTable(int x,int y,int w)
  {
   int half = (w-GH_GAP)/2;
   int rp   = 21;                                  // monospace row pitch (bigger font)
   int hgt  = 26 + 20 + rp*PT_ROWS + 8 + 42;       // acct + header + rows + summary
   oRect(PFX"pt_bg",x,y,w,hgt,C'16,18,24',CGOLD);

   //--- account status line (spans full width)
   oMono(PFX"pt_acct",x+12,y+7,"Balance: -   Equity: -   Daily P/L: -",CGOLD,GH_FS+1);

   int ty = y+30;                                  // table top
   string kk[2]={"b","s"}; string side[2]={"BUY","SELL"};
   for(int c=0;c<2;c++)
     {
      int cx = x + 12 + c*(half);
      oMono(PFX"pt_ttl_"+kk[c],cx,ty, side[c], c==0?CHBUY:CHSELL, GH_FS+1);
      oMono(PFX"pt_hdr_"+kk[c],cx,ty+19,PtHeader(),CGOLD,GH_FS);
      for(int r=0;r<PT_ROWS;r++)
         oMono(PFX"pt_"+kk[c]+"_"+(string)r, cx, ty+40+r*rp, " ", CTXT, GH_FS);
      //--- per-side summary (two stacked lines) under the rows
      int sy = ty+40+PT_ROWS*rp+6;
      oMono(PFX"pt_sum1_"+kk[c],cx,sy,   " ",CMUTE,GH_FS);
      oMono(PFX"pt_sum2_"+kk[c],cx,sy+18," ",CMUTE,GH_FS);
     }
  }

//--- The drag handle. Grabbing anywhere on this bar and moving the mouse
//--- repositions the whole panel. Height DRAGH; width passed in.
void BuildDragBar(int x,int y,int w)
  {
   oRect(PFX"drag",x,y,w,DRAGH,C'30,34,44',CGOLD);
   oLbl (PFX"drag_t",x+8,y+4,"::  GridHedge  -  drag to move",CGOLD,GH_FS,true);
  }

//--- minimized layout: just a compact title bar with the [+] and RUN/basket
void BuildMinimized()
  {
   int w=320, h=28;
   oRect(PFX"mini_bg",GH_X,GH_Y,w,h,C'18,20,26',CGOLD);
   //--- the mini bar itself is the drag handle (grab the empty area)
   oRect(PFX"drag",GH_X,GH_Y,w,h,C'18,20,26',CGOLD);
   oBtn (PFX"minbtn", GH_X+6, GH_Y+5, 24,18, "+", CBTN);   // maximize
   oLbl (PFX"mini_t", GH_X+36,GH_Y+7, "GridHedge", CGOLD, GH_FS+1, true);
   oBtn (PFX"m_run",  GH_X+130,GH_Y+5, 80,18, g.running?"RUN":"STOP", g.running?CON:COFF);
   oLbl (PFX"m_bskt", GH_X+222,GH_Y+8, "P/L: 0.00", CGOLD, GH_FS, true);
  }

void PanelCreate()
  {
   if(g_min) { BuildMinimized(); return; }

   int fw=GH_W*2+GH_GAP;
   //--- drag handle across the very top, then push the panels below it
   BuildDragBar(GH_X,GH_Y,fw);
   int bxB=GH_X, bxS=GH_X+GH_W+GH_GAP;
   int yb=BuildSide(bxB,"BUY","b",CHBUY,CBUYBG,g.buy);
   int ys=BuildSide(bxS,"SELL","s",CHSELL,CSELLBG,g.sell);
   //--- minimize button on the drag bar (top-right of the whole panel)
   oBtn(PFX"minbtn", GH_X+fw-24, GH_Y+2, 20,16, "-", CBTN);   // minimize

   int y=MathMax(yb,ys)+6;
   oRect(PFX"m_bg",GH_X,y,fw,28,C'18,20,26',CGOLD);
   oBtn(PFX"m_run",GH_X+8,  y+5,120,18,g.running?"RUNNING":"STOPPED",g.running?CON:COFF);
   oBtn(PFX"m_all",GH_X+138,y+5,120,18,"CLOSE ALL",COFF);
   oLbl(PFX"m_bskt",GH_X+270,y+8,"Basket P/L: 0.00",CGOLD,GH_FS+1,true);
   y+=34;
   BuildPosTable(GH_X,y,fw);
  }
void PanelDestroy(){ ObjectsDeleteAll(0,PFX); }

//--- refresh dynamic parts
void SidePanelUpdate(string k,const ENUM_POSITION_TYPE side,const SSide &s)
  {
   int n=SideCount(side); double pl=SideFloating(side);
   //--- live header: "<SIDE> - <broker> | Opened <Side> = <n>"
   if(ObjectFind(0,PFX+k+"hd")>=0)
      ObjectSetString(0,PFX+k+"hd",OBJPROP_TEXT, HeaderText(side==POSITION_TYPE_BUY?"BUY":"SELL"));
   if(ObjectFind(0,PFX+k+"sLvl")>=0)ObjectSetString(0,PFX+k+"sLvl",OBJPROP_TEXT,StringFormat("Levels: %d/%d",n,InpMaxLevels));
   if(ObjectFind(0,PFX+k+"sPL")>=0){ObjectSetString(0,PFX+k+"sPL",OBJPROP_TEXT,StringFormat("P/L: %.2f",pl));
                                    ObjectSetInteger(0,PFX+k+"sPL",OBJPROP_COLOR,pl>=0?CON:CHSELL);}
   if(ObjectFind(0,PFX+k+"ST")>=0) ObjectSetInteger(0,PFX+k+"ST",OBJPROP_BGCOLOR,(s.enabled&&!s.paused)?CON:CBTN);
   if(ObjectFind(0,PFX+k+"PU")>=0) ObjectSetInteger(0,PFX+k+"PU",OBJPROP_BGCOLOR,s.paused?CGOLD:CBTN);
   if(ObjectFind(0,PFX+k+"REP")>=0)ObjectSetInteger(0,PFX+k+"REP",OBJPROP_BGCOLOR,s.repeat?CON:CBTN);
   //--- toggle row buttons: label + color reflect current state
   string bsLbl=(k=="b")?"B+S":"S+B";
   if(ObjectFind(0,PFX+k+"tglSL")>=0){ ObjectSetString(0,PFX+k+"tglSL",OBJPROP_TEXT,s.slOn?"SL ON":"SL OFF");
                                       ObjectSetInteger(0,PFX+k+"tglSL",OBJPROP_BGCOLOR,s.slOn?CON:COFF); }
   if(ObjectFind(0,PFX+k+"tglBK")>=0){ ObjectSetString(0,PFX+k+"tglBK",OBJPROP_TEXT,s.baskOn?"BASK ON":"BASK OFF");
                                       ObjectSetInteger(0,PFX+k+"tglBK",OBJPROP_BGCOLOR,s.baskOn?CON:COFF); }
   if(ObjectFind(0,PFX+k+"tglBS")>=0){ ObjectSetString(0,PFX+k+"tglBS",OBJPROP_TEXT,s.helper?bsLbl+" ON":bsLbl+" OFF");
                                       ObjectSetInteger(0,PFX+k+"tglBS",OBJPROP_BGCOLOR,s.helper?CON:COFF); }
   for(int i=0;i<LVLS;i++)
      if(ObjectFind(0,PFX+k+"o"+(string)i)>=0)
        { ObjectSetString(0,PFX+k+"o"+(string)i,OBJPROP_TEXT,s.lv[i].on?"ON":"OFF");
          ObjectSetInteger(0,PFX+k+"o"+(string)i,OBJPROP_BGCOLOR,s.lv[i].on?CON:COFF); }
  }

//--- Fill one side's trade rows + summary lines. si: 0=BUY, 1=SELL.
void SideTableUpdate(const string k,const ENUM_POSITION_TYPE side,const int si,const SSide &s)
  {
   //--- collect THIS side's positions, oldest first
   ulong tk[]; int n=0;
   for(int i=0;i<PositionsTotal();i++)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=side)continue;
       ArrayResize(tk,n+1); tk[n]=t; n++; }

   //--- Safe = number of this side's positions sitting at/above break-even
   //--- (best-guess for the JNS "Safe" column; a locked/protected leg).
   int safe=0;
   for(int i=0;i<n;i++)
      if(PositionSelectByTicket(tk[i]))
        { double slv=PositionGetDouble(POSITION_SL);
          double pl =PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
          if(slv>0 || pl>=0) safe++; }

   for(int r=0;r<PT_ROWS;r++)
     {
      string nm=PFX"pt_"+k+"_"+(string)r; if(ObjectFind(0,nm)<0)continue;
      if(r<n && PositionSelectByTicket(tk[r]))
        {
         int    lvl = PosLevel(PositionGetString(POSITION_COMMENT));
         string row = (lvl<=1)? "G1" : LvName(MathMin(lvl-2,LVLS-1));   // G1/Gap2../ProS
         double vol = PositionGetDouble(POSITION_VOLUME);
         double pl  = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
         double slv = PositionGetDouble(POSITION_SL);
         double tpM,lockM; MoneyTargetsFor(side,lvl,tpM,lockM);        // Prof / Book(=lock)
         //--- State (guessed): LOCK if SL set; OPEN if floating; WAIT at be; STUCK if deep loss
         string st;
         if(slv>0)                 st="LOCK";
         else if(pl<=-InpSideSL*0.5 && InpSideSL>0) st="STUCK";
         else if(MathAbs(pl)<0.01)  st="WAIT";
         else                       st="OPEN";
         ObjectSetString(0,nm,OBJPROP_TEXT,StringFormat("%-4s %-5.2f %-6.2f %-6.2f %-6s %-8.2f %-4d",
              row, vol, tpM, lockM, st, pl, safe));
         ObjectSetInteger(0,nm,OBJPROP_COLOR, pl>=0?CTXT:CHSELL);
        }
      else ObjectSetString(0,nm,OBJPROP_TEXT," ");
     }

   //--- summary lines under this side's table
   double fl = SideFloating(side);
   string s1 = StringFormat("Prot:%s Lock:%s | Scalp:%d Total:%d",
                    PipStr(g.prot), DoubleToString(g.lock,2), m_scalp[si], m_total[si]);
   bool sideSlOn = (si==0)? g.buy.slOn : g.sell.slOn;
   string s2 = StringFormat("Bad:%d Booked:%.2f | Float:%.2f | SL:%s Trail:%s",
                    m_bad[si], m_booked[si], fl,
                    (sideSlOn&&InpSideSL>0)?DoubleToString(InpSideSL,0):"OFF", PipStr(g.trail));
   if(ObjectFind(0,PFX"pt_sum1_"+k)>=0){ ObjectSetString(0,PFX"pt_sum1_"+k,OBJPROP_TEXT,s1); }
   if(ObjectFind(0,PFX"pt_sum2_"+k)>=0){ ObjectSetString(0,PFX"pt_sum2_"+k,OBJPROP_TEXT,s2);
                                         ObjectSetInteger(0,PFX"pt_sum2_"+k,OBJPROP_COLOR, fl>=0?CMUTE:CHSELL); }
  }

void PosTableUpdate()
  {
   //--- account status line
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double eq =AccountInfoDouble(ACCOUNT_EQUITY);
   double day=(eq - m_start_balance);                 // session P/L vs start balance
   if(ObjectFind(0,PFX"pt_acct")>=0)
     { ObjectSetString(0,PFX"pt_acct",OBJPROP_TEXT,
         StringFormat("Balance: %.2f   Equity: %.2f   Daily P/L: %.2f  | Magic %I64d",
              bal,eq,day,(long)InpMagic));
       ObjectSetInteger(0,PFX"pt_acct",OBJPROP_COLOR, day>=0?CGOLD:CHSELL); }

   SideTableUpdate("b",POSITION_TYPE_BUY, 0, g.buy);
   SideTableUpdate("s",POSITION_TYPE_SELL,1, g.sell);
  }

void PanelUpdate()
  {
   if(!InpShowPanel)return;
   double bk=BasketFloating();

   if(g_min)
     {
      //--- minimized bar: compact run + P/L only
      if(ObjectFind(0,PFX"m_run")>=0){ObjectSetString(0,PFX"m_run",OBJPROP_TEXT,m_halted?"HALT":(g.running?"RUN":"STOP"));
                                      ObjectSetInteger(0,PFX"m_run",OBJPROP_BGCOLOR,m_halted?COFF:(g.running?CON:COFF));}
      if(ObjectFind(0,PFX"m_bskt")>=0){ObjectSetString(0,PFX"m_bskt",OBJPROP_TEXT,StringFormat("P/L: %.2f",bk));
                                       ObjectSetInteger(0,PFX"m_bskt",OBJPROP_COLOR,bk>=0?CON:CHSELL);}
      ChartRedraw(0);
      return;
     }

   SidePanelUpdate("b",POSITION_TYPE_BUY, g.buy);
   SidePanelUpdate("s",POSITION_TYPE_SELL,g.sell);
   if(ObjectFind(0,PFX"m_bskt")>=0){ObjectSetString(0,PFX"m_bskt",OBJPROP_TEXT,StringFormat("Basket P/L: %.2f",bk));
                                    ObjectSetInteger(0,PFX"m_bskt",OBJPROP_COLOR,bk>=0?CON:CHSELL);}
   if(ObjectFind(0,PFX"m_run")>=0){ObjectSetString(0,PFX"m_run",OBJPROP_TEXT,m_halted?"HALTED":(g.running?"RUNNING":"STOPPED"));
                                   ObjectSetInteger(0,PFX"m_run",OBJPROP_BGCOLOR,m_halted?COFF:(g.running?CON:COFF));}
   PosTableUpdate();
   ChartRedraw(0);
  }

//--- numeric read helper
double ReadNum(string n,double def){ if(ObjectFind(0,n)<0)return def; double v=StringToDouble(ObjectGetString(0,n,OBJPROP_TEXT)); return v; }

//====================================================================
//  EVENTS
//====================================================================
void PullSideEdits(string k,SSide &s)
  {
   //--- base fields (shared): lot/prot/lock/bs read from whichever side edited
   //--- Lot=lots; Profit/Lock = MONEY (acct ccy); Prot/B+S/Gap = PIPS; Target = PRICE.
   double v;
   v=ReadNum(PFX+k+"eLot",g.lot);              if(v>0) g.lot=v;
   v=ReadNum(PFX+k+"ePrf",g.tp);               if(v>0) g.tp=v;      // money
   v=ReadNum(PFX+k+"eLk", g.lock);             if(v>=0)g.lock=v;    // money (0=off)
   v=ReadNum(PFX+k+"ePrt",PtsToPips(g.prot));  if(v>=0)g.prot=PipsToPts(v);
   v=ReadNum(PFX+k+"eTr", PtsToPips(g.trail)); if(v>=0)g.trail=PipsToPts(v);   // trailing step (pips)
   v=ReadNum(PFX+k+"eTgt",s.target);           s.target=v;          // 0 = off (a PRICE)
   v=ReadNum(PFX+k+"eSt", s.start);            s.start=v;           // 0 = start at market (a PRICE)
   //--- per-level rows: gap in PIPS, profit/lock in MONEY (ProS Prof column = a PRICE anchor)
   for(int i=0;i<LVLS;i++)
     { bool isPros=(i==LVLS-1);
       double gg=ReadNum(PFX+k+"g"+(string)i,PtsToPips(s.lv[i].gap)); if(gg>0) s.lv[i].gap=PipsToPts(gg);
       double ll=ReadNum(PFX+k+"l"+(string)i,s.lv[i].lot);            if(ll>0) s.lv[i].lot=ll;
       double kk=ReadNum(PFX+k+"k"+(string)i,s.lv[i].lock);          if(kk>=0)s.lv[i].lock=kk;
       if(isPros)
         { //--- ProS Prof field is a PRICE anchor. A big number (>=100 on gold) = a price;
           //--- a small number = treat as money tp with no anchor.
           double pv=ReadNum(PFX+k+"p"+(string)i, s.lv[i].prosAnchor>0? s.lv[i].prosAnchor : s.lv[i].tp);
           if(pv>=100.0){ s.lv[i].prosAnchor=pv; }
           else { s.lv[i].prosAnchor=0.0; if(pv>0) s.lv[i].tp=pv; } }
       else
         { double pp=ReadNum(PFX+k+"p"+(string)i,s.lv[i].tp);        if(pp>0) s.lv[i].tp=pp; } }
  }

//--- SY: copy one side's tunable settings to the other side. src = "b" or "s".
//--- Copies the per-level grid table + Start/Target/toggles (but not open positions).
void SyncSides(const string src)
  {
   SSide from = (src=="b") ? g.buy : g.sell;
   SSide to;
   if(src=="b") to=g.sell; else to=g.buy;
   for(int i=0;i<LVLS;i++) to.lv[i]=from.lv[i];
   to.start=from.start; to.target=from.target;
   to.repeat=from.repeat; to.slOn=from.slOn; to.baskOn=from.baskOn; to.helper=from.helper;
   if(src=="b") g.sell=to; else g.buy=to;
   PanelDestroy(); PanelCreate(); PanelUpdate();
  }

void SideReport(const ENUM_POSITION_TYPE side)
  {
   int n=SideCount(side); double pl=SideFloating(side);
   bool f=false; double last=LastEntryPrice(side,f);
   Log(StringFormat("REPORT %s: levels=%d floatPL=%.2f lastEntry=%.*f",
        side==POSITION_TYPE_BUY?"BUY":"SELL",n,pl,m_digits, f?last:0.0));
  }

void OnChartEvent(const int id,const long &lp,const double &dp,const string &sp)
  {
   //================= PANEL DRAG (mouse move) =================
   //--- lp = mouse X, dp = mouse Y, sp = button/modifier state ("1" = left down)
   if(id==CHARTEVENT_MOUSE_MOVE)
     {
      int mx=(int)lp, my=(int)dp;
      bool ldown=(StringToInteger(sp) & 1)!=0;   // bit0 = left button held
      if(ldown)
        {
         //--- start a drag if the press landed on the drag bar
         if(!g_drag)
           {
            int bx=GH_X, by=GH_Y, bw=(g_min? 320 : (GH_W*2+GH_GAP)), bh=(g_min?28:DRAGH);
            if(mx>=bx && mx<=bx+bw && my>=by && my<=by+bh)
              { g_drag=true; g_dragDX=mx-GH_X; g_dragDY=my-GH_Y; }
           }
         if(g_drag)
           {
            g_ox = mx-g_dragDX; if(g_ox<0) g_ox=0;
            g_oy = my-g_dragDY; if(g_oy<0) g_oy=0;
            PanelDestroy(); PanelCreate(); PanelUpdate();
           }
        }
      else if(g_drag)
        {
         //--- released: stop dragging and persist the new origin
         g_drag=false;
         GlobalVariableSet(PFX"ox",g_ox); GlobalVariableSet(PFX"oy",g_oy);
        }
      return;
     }

   if(id==CHARTEVENT_OBJECT_ENDEDIT)
     { if(StringFind(sp,PFX)!=0)return;
       PullSideEdits("b",g.buy); PullSideEdits("s",g.sell);
       Log(StringFormat("edit: lot=%.2f prot=%d lock=%.2f trail=%d buyStart=%.2f sellStart=%.2f buyTgt=%.2f sellTgt=%.2f",
            g.lot,g.prot,g.lock,g.trail,g.buy.start,g.sell.start,g.buy.target,g.sell.target));
       ChartRedraw(0); return; }

   if(id!=CHARTEVENT_OBJECT_CLICK)return;
   if(StringFind(sp,PFX)!=0)return;

   //--- minimize / maximize toggle: rebuild the panel in the other mode
   if(sp==PFX"minbtn"){ g_min=!g_min; PanelDestroy(); PanelCreate(); PanelUpdate(); return; }
   //--- master
   if(sp==PFX"m_run"){ if(m_halted){m_halted=false;m_start_equity=AccountInfoDouble(ACCOUNT_EQUITY);Log("halt cleared");} g.running=!g.running; }
   else if(sp==PFX"m_all"){ CloseAll("panel CLOSE ALL"); }
   //--- BUY controls
   else if(sp==PFX"bST"){ g.buy.enabled=true; g.buy.paused=false; Log("BUY ST: started"); }
   else if(sp==PFX"bPU"){ g.buy.paused=!g.buy.paused; Log(StringFormat("BUY PU: %s",g.buy.paused?"paused":"resumed")); }
   else if(sp==PFX"bCL"){ g.buy.enabled=false; CloseSide(POSITION_TYPE_BUY,"CL stop+close"); Log("BUY CL: stopped + closed"); }
   else if(sp==PFX"bSY"){ SyncSides("b"); Log("BUY SY: copied BUY settings to SELL"); }
   else if(sp==PFX"bRE"){ RestartSide(POSITION_TYPE_BUY); }
   else if(sp==PFX"bREP"){ g.buy.repeat=!g.buy.repeat; Log(StringFormat("BUY REP: %s",g.buy.repeat?"on":"off")); }
   else if(sp==PFX"btglSL"){ g.buy.slOn=!g.buy.slOn; Log(StringFormat("BUY SL: %s",g.buy.slOn?"ON":"OFF")); }
   else if(sp==PFX"btglBK"){ g.buy.baskOn=!g.buy.baskOn; Log(StringFormat("BUY BASK: %s",g.buy.baskOn?"ON":"OFF")); }
   else if(sp==PFX"btglBS"){ g.buy.helper=!g.buy.helper; Log(StringFormat("BUY B+S helper: %s",g.buy.helper?"ON":"OFF")); }
   else if(sp==PFX"bclsAll"){ CloseSide(POSITION_TYPE_BUY,"panel close BUY"); }
   //--- SELL controls
   else if(sp==PFX"sST"){ g.sell.enabled=true; g.sell.paused=false; Log("SELL ST: started"); }
   else if(sp==PFX"sPU"){ g.sell.paused=!g.sell.paused; Log(StringFormat("SELL PU: %s",g.sell.paused?"paused":"resumed")); }
   else if(sp==PFX"sCL"){ g.sell.enabled=false; CloseSide(POSITION_TYPE_SELL,"CL stop+close"); Log("SELL CL: stopped + closed"); }
   else if(sp==PFX"sSY"){ SyncSides("s"); Log("SELL SY: copied SELL settings to BUY"); }
   else if(sp==PFX"sRE"){ RestartSide(POSITION_TYPE_SELL); }
   else if(sp==PFX"sREP"){ g.sell.repeat=!g.sell.repeat; Log(StringFormat("SELL REP: %s",g.sell.repeat?"on":"off")); }
   else if(sp==PFX"stglSL"){ g.sell.slOn=!g.sell.slOn; Log(StringFormat("SELL SL: %s",g.sell.slOn?"ON":"OFF")); }
   else if(sp==PFX"stglBK"){ g.sell.baskOn=!g.sell.baskOn; Log(StringFormat("SELL BASK: %s",g.sell.baskOn?"ON":"OFF")); }
   else if(sp==PFX"stglBS"){ g.sell.helper=!g.sell.helper; Log(StringFormat("SELL B+S helper: %s",g.sell.helper?"ON":"OFF")); }
   else if(sp==PFX"sclsAll"){ CloseSide(POSITION_TYPE_SELL,"panel close SELL"); }
   else
     {
      //--- per-level ON/OFF toggles: keys like "b o<i>" / "s o<i>"
      for(int i=0;i<LVLS;i++)
        { if(sp==PFX"b"+"o"+(string)i){ g.buy.lv[i].on=!g.buy.lv[i].on;  Log(StringFormat("BUY %s %s",LvName(i),g.buy.lv[i].on?"ON":"OFF")); }
          if(sp==PFX"s"+"o"+(string)i){ g.sell.lv[i].on=!g.sell.lv[i].on;Log(StringFormat("SELL %s %s",LvName(i),g.sell.lv[i].on?"ON":"OFF")); } }
     }
   ObjectSetInteger(0,sp,OBJPROP_STATE,false);
   PanelUpdate();
  }
//+------------------------------------------------------------------+
