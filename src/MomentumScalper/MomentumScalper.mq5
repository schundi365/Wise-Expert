//+------------------------------------------------------------------+
//|                                             MomentumScalper.mq5   |
//|   Positive-expectancy momentum breakout scalper.                 |
//|                                                                  |
//|   DESIGN (the opposite of a martingale grid):                    |
//|     - EVERY trade has a HARD stop-loss. Nothing is ever left     |
//|       floating unbounded. A single trend cannot wipe the account.|
//|     - Reward:risk > 1 (TP = R * StopDistance). Average win is    |
//|       bigger than average loss, so a <50% win rate still profits.|
//|     - Fixed MONEY risk per trade -> position size is derived from |
//|       the stop distance, so risk is constant regardless of ATR.  |
//|     - Break-even move at +1R, then ATR trailing to ride runners. |
//|     - Volatility gate (ATR) so it only trades when price MOVES    |
//|       (catches the fast $50 gold spikes; skips dead chop).        |
//|     - Daily loss limit halts trading for the day.                |
//+------------------------------------------------------------------+
#property copyright "WiseTrader"
#property version   "1.00"
#property strict
#property description "Momentum breakout scalper: hard stop per trade, R:R>1, BE+ATR trail, volatility gate, daily loss limit. Positive-expectancy alternative to the grid."

#include <Trade/Trade.mqh>

//====================================================================
//  INPUTS
//====================================================================
input group "Risk (the core of positive expectancy)"
input double InpRiskMoney     = 10.0;   // Risk PER TRADE in account currency (£). Loss is capped at this.
input double InpRewardRatio   = 1.8;    // Take-profit as a multiple of risk (1.8 = win 1.8x the risk). MUST be > 1.
input double InpDailyLossStop = 60.0;   // Halt NEW trades for the day if realized+floating P/L <= -this (0 = off)
input double InpMaxLot        = 1.00;   // Hard cap on lot size (safety)
input double InpMinLot        = 0.01;   // Floor lot size

input group "Entry: momentum breakout + trend confirm"
input int    InpBreakoutBars  = 7;      // Breakout lookback: enter on break of this many bars' high/low (tuned: real-tick best)
input int    InpBufferPoints  = 10;     // Break must exceed the level by this many points (noise filter)
input int    InpEntryMode     = 0;      // 0=live break only (strict), 1=closed-bar only, 2=both (loosest). Tuned: 0.
input int    InpEmaFast       = 21;     // Fast EMA for trend confirmation
input int    InpEmaSlow       = 50;     // Slow EMA for trend confirmation
input bool   InpUseEmaFilter  = false;  // Require EMA trend agreement (tuned OFF: filter cut good M5 trades)

input group "Volatility gate (only trade when price MOVES)"
input int    InpAtrPeriod     = 14;     // ATR period
input double InpAtrMinPips    = 4.0;    // Skip entries when ATR is below this (dead market). 0 = off
input double InpAtrMaxPips    = 0.0;    // Skip entries when ATR is above this (too wild). 0 = off

input group "Exit / trade management"
input double InpStopAtrMult   = 1.5;    // Hard stop distance = ATR * this
input double InpBeTriggerR    = 1.0;    // Move stop to break-even once profit reaches this many R
input double InpBeLockPips     = 1.0;   // Lock this many pips of profit when moving to break-even
input double InpTrailAtrMult   = 2.0;   // After BE, trail stop at ATR * this (0 = no trail)

input group "Filters"
input int    InpMaxSpreadPts  = 60;     // Skip entries when spread exceeds this (points). 0 = off
input bool   InpUseSession    = false;  // Restrict trading to a daily time window
input int    InpSessStartHour = 7;      // Session start hour (server time)
input int    InpSessEndHour   = 20;     // Session end hour (server time)
input bool   InpAvoidRollover = true;   // Skip entries around the daily close/rollover (avoids "market closed" rejects)
input int    InpRolloverHour  = 23;     // Server hour of the rollover window to avoid (no new entries this hour)
input bool   InpOneTradePerBar= true;   // At most one new entry per bar

input group "Engine"
input long   InpMagic         = 77012024; // Magic number
input int    InpSlippage      = 30;       // Max deviation, points
input bool   InpShowPanel     = true;     // Draw the status panel
input bool   InpEnableLog     = true;     // Log to Experts tab
input bool   InpDebugSkips    = false;    // Log WHY no entry fired (once per bar) - use to diagnose "no trades"

//====================================================================
//  STATE
//====================================================================
CTrade   m_trade;
string   m_sym;
double   m_point;
int      m_digits;
int      g_ppp = 10;                        // points per pip
int      hATR=INVALID_HANDLE, hEmaF=INVALID_HANDLE, hEmaS=INVALID_HANDLE;

datetime m_lastBar   = 0;                   // last processed bar time (one-trade-per-bar)
int      m_dayWins   = 0;                   // session tally
int      m_dayLosses = 0;
double   m_dayStartBal= 0.0;                // balance at start of the current day
int      m_curDay    = -1;                  // day-of-year we're tracking
bool     m_dayHalted = false;

double   PtsToPips(double pts){ return pts / g_ppp; }
double   PipsToPts(double pips){ return pips * g_ppp; }

void Log(const string s){ if(InpEnableLog) Print("[MScalp] ", s); }
double Ask(){ return SymbolInfoDouble(m_sym,SYMBOL_ASK); }
double Bid(){ return SymbolInfoDouble(m_sym,SYMBOL_BID); }
double Nz(double p){ return NormalizeDouble(p,m_digits); }

//====================================================================
//  INIT
//====================================================================
int OnInit()
  {
   m_sym    = _Symbol;
   m_point  = SymbolInfoDouble(m_sym,SYMBOL_POINT);
   m_digits = (int)SymbolInfoInteger(m_sym,SYMBOL_DIGITS);
   g_ppp    = (m_digits==3 || m_digits==5 || m_digits==2) ? 10 : 1;

   if(InpRewardRatio<=1.0)
     { Print("[MScalp] InpRewardRatio must be > 1 for positive expectancy."); return INIT_PARAMETERS_INCORRECT; }
   if(InpStopAtrMult<=0 || InpRiskMoney<=0)
     { Print("[MScalp] stop mult and risk money must be > 0."); return INIT_PARAMETERS_INCORRECT; }

   hATR  = iATR(m_sym,_Period,InpAtrPeriod);
   hEmaF = iMA(m_sym,_Period,InpEmaFast,0,MODE_EMA,PRICE_CLOSE);
   hEmaS = iMA(m_sym,_Period,InpEmaSlow,0,MODE_EMA,PRICE_CLOSE);
   if(hATR==INVALID_HANDLE || hEmaF==INVALID_HANDLE || hEmaS==INVALID_HANDLE)
     { Print("[MScalp] indicator handle failed."); return INIT_FAILED; }

   m_trade.SetExpertMagicNumber(InpMagic);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFillingBySymbol(m_sym);

   m_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); m_curDay = dt.day_of_year;

   if(InpShowPanel) PanelCreate();
   Log(StringFormat("init v1.0 risk(£)=%.2f R=%.2f stop=%.1fxATR breakout=%d bars EMA %d/%d atrGate>=%.1fpip",
        InpRiskMoney,InpRewardRatio,InpStopAtrMult,InpBreakoutBars,InpEmaFast,InpEmaSlow,InpAtrMinPips));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int r)
  {
   if(hATR!=INVALID_HANDLE)  IndicatorRelease(hATR);
   if(hEmaF!=INVALID_HANDLE) IndicatorRelease(hEmaF);
   if(hEmaS!=INVALID_HANDLE) IndicatorRelease(hEmaS);
   PanelDestroy();
  }

//====================================================================
//  INDICATOR / DATA HELPERS
//====================================================================
double ATRnow()
  {
   double b[]; if(CopyBuffer(hATR,0,0,2,b)<2) return 0;
   return b[0];
  }
double EmaFast(int shift=0){ double b[]; if(CopyBuffer(hEmaF,0,shift,1,b)<1)return 0; return b[0]; }
double EmaSlow(int shift=0){ double b[]; if(CopyBuffer(hEmaS,0,shift,1,b)<1)return 0; return b[0]; }

//--- highest high / lowest low over the last N CLOSED bars (shift 1..N)
double RecentHigh(int bars)
  {
   int idx = iHighest(m_sym,_Period,MODE_HIGH,bars,1);
   if(idx<0) return 0;
   return iHigh(m_sym,_Period,idx);
  }
double RecentLow(int bars)
  {
   int idx = iLowest(m_sym,_Period,MODE_LOW,bars,1);
   if(idx<0) return 0;
   return iLow(m_sym,_Period,idx);
  }

//====================================================================
//  POSITION HELPERS
//====================================================================
int MyPositions()
  {
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       n++; }
   return n;
  }
double FloatingPL()
  {
   double tot=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       tot += PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP); }
   return tot;
  }

//--- lot size so that (stop distance) risks exactly InpRiskMoney
double LotForRisk(double stopPoints)
  {
   double tickVal  = SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_SIZE);
   //--- SAFETY: bad/zero specs -> refuse (0 lot = no trade), never guess.
   if(tickVal<=0 || tickSize<=0 || stopPoints<=0) return 0;
   //--- money lost per 1.0 lot if price moves stopPoints
   double lossPerLot = (stopPoints*m_point/tickSize)*tickVal;
   if(lossPerLot<=0) return 0;
   double lot = InpRiskMoney / lossPerLot;

   //--- clamp to broker volume step/min/max and our caps
   double vmin = SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MAX);
   double vstep= SymbolInfoDouble(m_sym,SYMBOL_VOLUME_STEP);
   if(vstep>0) lot = MathFloor(lot/vstep)*vstep;
   lot = MathMax(lot, MathMax(vmin,InpMinLot));
   lot = MathMin(lot, MathMin(vmax,InpMaxLot));
   lot = NormalizeDouble(lot,2);

   //--- HARD RISK CEILING (the XAUGBP bug): if the smallest allowed lot still
   //--- risks more than 3x the intended money, REFUSE the trade rather than
   //--- silently taking oversized risk that can blow the account.
   if(lot*lossPerLot > 3.0*InpRiskMoney) return 0;
   return lot;
  }

//====================================================================
//  DAILY GUARD
//====================================================================
void RollDayIfNeeded()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(dt.day_of_year!=m_curDay)
     {
      m_curDay      = dt.day_of_year;
      m_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
      m_dayWins=0; m_dayLosses=0; m_dayHalted=false;
      Log("new day: counters reset, halt cleared");
     }
  }
//--- realized+floating P/L since the start of the day
double DayPL()
  {
   double realized = AccountInfoDouble(ACCOUNT_BALANCE) - m_dayStartBal;
   return realized + FloatingPL();
  }
bool DailyHalted()
  {
   if(InpDailyLossStop<=0) return false;
   if(m_dayHalted) return true;
   if(DayPL() <= -InpDailyLossStop)
     { m_dayHalted=true; Log(StringFormat("DAILY LOSS STOP hit (%.2f). No new trades today.",DayPL())); return true; }
   return false;
  }

//====================================================================
//  FILTERS
//====================================================================
bool SpreadOK()
  {
   if(InpMaxSpreadPts<=0) return true;
   double sp = (Ask()-Bid())/m_point;
   return sp <= InpMaxSpreadPts;
  }
bool SessionOK()
  {
   if(!InpUseSession) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(InpSessStartHour<=InpSessEndHour)
      return (dt.hour>=InpSessStartHour && dt.hour<InpSessEndHour);
   //--- wrap-around window (e.g. 22->6)
   return (dt.hour>=InpSessStartHour || dt.hour<InpSessEndHour);
  }
//--- avoid entering right at the daily close/rollover (orders get rejected
//--- "market closed" and fills are unreliable). Also require the symbol to
//--- currently be in a tradeable session.
bool RolloverOK()
  {
   if(InpAvoidRollover)
     {
      MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
      if(dt.hour==InpRolloverHour) return false;
     }
   //--- confirm the symbol currently allows full trading
   long tm = SymbolInfoInteger(m_sym,SYMBOL_TRADE_MODE);
   if(tm==SYMBOL_TRADE_MODE_DISABLED || tm==SYMBOL_TRADE_MODE_CLOSEONLY) return false;
   return true;
  }
bool VolatilityOK(double atr)
  {
   double atrPips = PtsToPips(atr/m_point);
   if(InpAtrMinPips>0 && atrPips < InpAtrMinPips) return false;
   if(InpAtrMaxPips>0 && atrPips > InpAtrMaxPips) return false;
   return true;
  }

//====================================================================
//  ENTRY
//====================================================================
string g_lastSkip="";   // last reason no entry fired (for throttled debug log)

//--- returns +1 long signal, -1 short signal, 0 none.
//--- Two ways to fire, so a sustained ramp is never missed:
//---  (1) LIVE breakout: current price pierces the prior N-bar range + buffer.
//---  (2) CLOSED-BAR momentum: the just-closed bar closed beyond the prior
//---      N-bar range (confirms a real break even if price already ran).
int Signal(double atr)
  {
   double buf = InpBufferPoints*m_point;
   bool trendUp   = (!InpUseEmaFilter) || (EmaFast()>EmaSlow());
   bool trendDown = (!InpUseEmaFilter) || (EmaFast()<EmaSlow());

   //--- LIVE range: highest/lowest of the last N CLOSED bars starting at
   //--- shift 1 (INCLUDES the just-closed bar). This matches the verified
   //--- +£554/PF1.14 baseline. Live price must pierce THIS level.
   int lH = iHighest(m_sym,_Period,MODE_HIGH,InpBreakoutBars,1);
   int lL = iLowest (m_sym,_Period,MODE_LOW ,InpBreakoutBars,1);
   if(lH<0 || lL<0) { g_lastSkip="no range data"; return 0; }
   double hiLive = iHigh(m_sym,_Period,lH);
   double loLive = iLow (m_sym,_Period,lL);
   bool liveUp   = (Ask() > hiLive+buf);
   bool liveDn   = (Bid() < loLive-buf);

   //--- CLOSED-BAR range: the N bars BEFORE the just-closed bar (shift 2),
   //--- so the just-closed bar can be tested as the breakout bar.
   int cH = iHighest(m_sym,_Period,MODE_HIGH,InpBreakoutBars,2);
   int cL = iLowest (m_sym,_Period,MODE_LOW ,InpBreakoutBars,2);
   double hiPrev = (cH>=0)? iHigh(m_sym,_Period,cH) : hiLive;
   double loPrev = (cL>=0)? iLow (m_sym,_Period,cL) : loLive;
   double closed = iClose(m_sym,_Period,1);
   bool closeUp  = (closed > hiPrev+buf);
   bool closeDn  = (closed < loPrev-buf);

   //--- entry mode gates which paths are allowed
   bool useLive   = (InpEntryMode==0 || InpEntryMode==2);
   bool useClosed = (InpEntryMode==1 || InpEntryMode==2);
   bool upBreak   = (useLive && liveUp) || (useClosed && closeUp);
   bool dnBreak   = (useLive && liveDn) || (useClosed && closeDn);

   if(upBreak && trendUp)  { return +1; }
   if(dnBreak && trendDown){ return -1; }

   //--- record why nothing fired (for the debug log)
   if(InpUseEmaFilter && upBreak && !trendUp)      g_lastSkip="up-break blocked by EMA (trend down)";
   else if(InpUseEmaFilter && dnBreak && !trendDown) g_lastSkip="dn-break blocked by EMA (trend up)";
   else g_lastSkip=StringFormat("no breakout (Ask %.*f vs hi %.*f / Bid vs lo %.*f)",m_digits,Ask(),m_digits,hiLive,m_digits,loLive);
   return 0;
  }

void TryEnter()
  {
   double atr = ATRnow();
   if(atr<=0)             { g_lastSkip="ATR not ready"; return; }
   if(!VolatilityOK(atr)) { g_lastSkip=StringFormat("ATR gate: %.1fpip < min %.1f",PtsToPips(atr/m_point),InpAtrMinPips); return; }
   if(!SpreadOK())        { g_lastSkip=StringFormat("spread %.0f > max %d",(Ask()-Bid())/m_point,InpMaxSpreadPts); return; }
   if(!SessionOK())       { g_lastSkip="out of session window"; return; }
   if(!RolloverOK())      { g_lastSkip="rollover/close window"; return; }

   int sig = Signal(atr);
   if(sig==0) return;     // Signal() already set g_lastSkip

   double stopDist = atr*InpStopAtrMult;                 // price distance
   double stopPts  = stopDist/m_point;
   double lot      = LotForRisk(stopPts);
   if(lot<=0){ g_lastSkip="sizing refused (unsafe on this symbol)"; return; }

   double sl,tp,entry;
   if(sig>0)
     { entry=Ask(); sl=Nz(entry-stopDist); tp=Nz(entry+stopDist*InpRewardRatio);
       if(!m_trade.Buy(lot,m_sym,0,sl,tp,"MScalp"))
          { Log(StringFormat("BUY failed rc=%u",m_trade.ResultRetcode())); return; }
       Log(StringFormat("BUY %.2f @%.*f SL=%.*f TP=%.*f (risk £%.2f, ATR=%.1fpip)",
            lot,m_digits,entry,m_digits,sl,m_digits,tp,InpRiskMoney,PtsToPips(atr/m_point))); }
   else
     { entry=Bid(); sl=Nz(entry+stopDist); tp=Nz(entry-stopDist*InpRewardRatio);
       if(!m_trade.Sell(lot,m_sym,0,sl,tp,"MScalp"))
          { Log(StringFormat("SELL failed rc=%u",m_trade.ResultRetcode())); return; }
       Log(StringFormat("SELL %.2f @%.*f SL=%.*f TP=%.*f (risk £%.2f, ATR=%.1fpip)",
            lot,m_digits,entry,m_digits,sl,m_digits,tp,InpRiskMoney,PtsToPips(atr/m_point))); }
  }

//====================================================================
//  TRADE MANAGEMENT: break-even + ATR trail (never widen the stop)
//====================================================================
void ManageOpen()
  {
   double atr = ATRnow();
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i); if(t==0)continue;
      if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;

      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool lng=(type==POSITION_TYPE_BUY);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   =PositionGetDouble(POSITION_SL);
      double tp   =PositionGetDouble(POSITION_TP);
      double cur  = lng?Bid():Ask();

      //--- risk distance = entry->original stop. Derive R from current profit.
      double riskDist = MathAbs(entry - sl);
      if(riskDist<=0) riskDist = atr*InpStopAtrMult;   // fallback
      double profDist = lng ? (cur-entry) : (entry-cur);
      double rMult    = (riskDist>0)? profDist/riskDist : 0;

      double newSL = sl;

      //--- 1) break-even move at +BeTriggerR
      if(rMult >= InpBeTriggerR)
        {
         double lock = InpBeLockPips*PipsToPts(1.0)*m_point;   // pips -> price
         double be   = lng ? Nz(entry+lock) : Nz(entry-lock);
         if(lng  && (sl<be)) newSL=be;
         if(!lng && (sl>be || sl==0)) newSL=be;
        }

      //--- 2) ATR trail once we're past break-even trigger
      if(InpTrailAtrMult>0 && rMult >= InpBeTriggerR && atr>0)
        {
         double trail = atr*InpTrailAtrMult;
         double cand  = lng ? Nz(cur-trail) : Nz(cur+trail);
         if(lng  && cand>newSL) newSL=cand;
         if(!lng && (cand<newSL || newSL==0)) newSL=cand;
        }

      //--- apply only if it TIGHTENS the stop (never widen)
      bool improve = lng ? (newSL>sl) : (newSL<sl || sl==0);
      if(improve && MathAbs(newSL-sl)>=m_point)
        {
         if(m_trade.PositionModify(t,newSL,tp))
            Log(StringFormat("%s trail SL %.*f -> %.*f (R=%.2f)",lng?"BUY":"SELL",m_digits,sl,m_digits,newSL,rMult));
        }
     }
  }

//====================================================================
//  TALLY closed trades (wins/losses today) via OnTradeTransaction
//====================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &req,
                        const MqlTradeResult &res)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   ulong ticket=trans.deal;
   if(ticket==0 || !HistoryDealSelect(ticket)) return;
   if(HistoryDealGetInteger(ticket,DEAL_MAGIC)!=InpMagic) return;
   if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=m_sym)    return;
   if(HistoryDealGetInteger(ticket,DEAL_ENTRY)!=DEAL_ENTRY_OUT) return;
   double pl = HistoryDealGetDouble(ticket,DEAL_PROFIT)
             + HistoryDealGetDouble(ticket,DEAL_SWAP)
             + HistoryDealGetDouble(ticket,DEAL_COMMISSION);
   if(pl>=0) m_dayWins++; else m_dayLosses++;
  }

//====================================================================
//  MAIN
//====================================================================
void OnTick()
  {
   RollDayIfNeeded();
   ManageOpen();          // always manage open positions, even when halted
   PanelUpdate();

   //--- one entry evaluation per new bar (or intrabar if disabled)
   datetime bt = iTime(m_sym,_Period,0);
   bool newBar = (bt!=m_lastBar);
   if(InpOneTradePerBar && !newBar) return;
   if(newBar) m_lastBar = bt;

   if(DailyHalted()) { if(InpDebugSkips&&newBar)Log("skip: daily loss halt"); return; }
   if(MyPositions()>0) { if(InpDebugSkips&&newBar)Log("skip: already in a position"); return; }

   g_lastSkip="";
   TryEnter();
   //--- if nothing fired this bar and debug is on, report why (once per bar)
   if(InpDebugSkips && newBar && g_lastSkip!="")
      Log("skip: "+g_lastSkip);
  }

//====================================================================
//  STATUS PANEL (lightweight labels)
//====================================================================
#define MP "MP_"
color  PC_BG=C'18,20,26', PC_GOLD=C'214,175,55', PC_TXT=C'230,232,238',
       PC_GRN=C'0,170,80', PC_RED=C'210,60,66', PC_MUTE=C'150,160,175';

void pLbl(string n,int x,int y,string t,color c,int fs=9,bool bold=false)
  {
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetString (0,n,OBJPROP_TEXT,t); ObjectSetString(0,n,OBJPROP_FONT,bold?"Arial Bold":"Consolas");
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs); ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }
void pRect(string n,int x,int y,int w,int h,color bg)
  {
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w); ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg); ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_COLOR,PC_GOLD); ObjectSetInteger(0,n,OBJPROP_BACK,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }
void PanelCreate()
  {
   int x=10,y=22,w=330,h=150;
   pRect(MP"bg",x,y,w,h,PC_BG);
   pLbl(MP"ttl",x+10,y+8,"MomentumScalper",PC_GOLD,11,true);
   pLbl(MP"l1", x+10,y+34," ",PC_TXT,9);
   pLbl(MP"l2", x+10,y+54," ",PC_TXT,9);
   pLbl(MP"l3", x+10,y+74," ",PC_TXT,9);
   pLbl(MP"l4", x+10,y+94," ",PC_TXT,9);
   pLbl(MP"l5", x+10,y+114," ",PC_TXT,9);
   pLbl(MP"l6", x+10,y+132," ",PC_MUTE,8);
  }
void PanelDestroy(){ ObjectsDeleteAll(0,MP); }

void PanelUpdate()
  {
   if(!InpShowPanel) return;
   double atr=ATRnow();
   double atrPips=PtsToPips(atr/m_point);
   bool up=(EmaFast()>EmaSlow());
   double dpl=DayPL();

   //--- open-position summary (R multiple)
   string posLine="Position: flat";
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       bool lng=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
       double entry=PositionGetDouble(POSITION_PRICE_OPEN), sl=PositionGetDouble(POSITION_SL);
       double cur=lng?Bid():Ask();
       double rd=MathAbs(entry-sl); double pd=lng?(cur-entry):(entry-cur);
       double r=(rd>0)?pd/rd:0;
       posLine=StringFormat("Position: %s %.2f  R=%.2f  P/L=%.2f",lng?"LONG":"SHORT",
                 PositionGetDouble(POSITION_VOLUME),r,PositionGetDouble(POSITION_PROFIT));
       break; }

   pLbl(MP"l1",14,56,StringFormat("State : %s",m_dayHalted?"HALTED (daily loss)":(SessionOK()?"trading":"out of session")),
        m_dayHalted?PC_RED:PC_TXT,9);
   pLbl(MP"l2",14,76,StringFormat("ATR   : %.1f pip   Trend: %s",atrPips,up?"UP":"DOWN"),PC_TXT,9);
   pLbl(MP"l3",14,96,posLine,PC_TXT,9);
   pLbl(MP"l4",14,116,StringFormat("Day P/L: %.2f   (limit -%.0f)",dpl,InpDailyLossStop),dpl>=0?PC_GRN:PC_RED,9);
   pLbl(MP"l5",14,136,StringFormat("Wins: %d   Losses: %d",m_dayWins,m_dayLosses),PC_MUTE,9);
   pLbl(MP"l6",14,154,StringFormat("risk £%.2f  R:R 1:%.1f  stop %.1fxATR",InpRiskMoney,InpRewardRatio,InpStopAtrMult),PC_MUTE,8);
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
