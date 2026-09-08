//+------------------------------------------------------------------+
//|                                              MeanReversion.mq5    |
//|   Positive-expectancy FADE scalper (the inverse edge of the      |
//|   MomentumScalper breakout EA).                                  |
//|                                                                  |
//|   Idea: in RANGING conditions price over-extends then reverts.   |
//|   - SHORT when price pokes ABOVE the upper Bollinger band AND     |
//|     RSI is overbought  (stretched too far up -> fade back down). |
//|   - LONG  when price pokes BELOW the lower band AND RSI oversold. |
//|                                                                  |
//|   SAME safety framework as the breakout EA:                      |
//|   - HARD stop-loss on every trade (ATR based). Nothing floats    |
//|     unbounded -> a trend cannot wipe the account.                |
//|   - Reward:risk configurable (fades usually target ~1R back to   |
//|     the mean, so R can be <=1 here; expectancy comes from a HIGH  |
//|     win rate, not a big R).                                       |
//|   - Trend guard: do NOT fade a strong trend (that's how fade     |
//|     strategies blow up). Only trade when the market is ranging.   |
//|                                                                  |
//|   Built to run ALONGSIDE MomentumScalper on a hedging account    |
//|   (different magic) to raise overall trade frequency - but ONLY  |
//|   if it proves positive-expectancy on real ticks standalone.     |
//+------------------------------------------------------------------+
#property copyright "WiseTrader"
#property version   "1.00"
#property strict
#property description "Mean-reversion fade scalper: fade Bollinger+RSI extremes in ranging markets, hard ATR stop, R-based TP, trend guard. Independent positive-expectancy leg to pair with the breakout EA."

#include <Trade/Trade.mqh>

//====================================================================
//  INPUTS
//====================================================================
input group "Risk"
input double InpRiskMoney     = 10.0;   // Risk PER TRADE in account currency (£). Loss capped at this.
input double InpRewardRatio   = 1.0;    // TP as a multiple of risk. Fades target the mean, so ~1.0 is normal.
input double InpDailyLossStop = 60.0;   // Halt NEW trades for the day if realized+floating P/L <= -this (0 = off)
input double InpMaxLot        = 1.00;   // Hard cap on lot size
input double InpMinLot        = 0.01;   // Floor lot size

input group "Entry: Bollinger + RSI extreme (fade)"
input int    InpBbPeriod      = 20;     // Bollinger period
input double InpBbDev         = 2.0;    // Bollinger std-dev multiplier (band width)
input int    InpRsiPeriod     = 14;     // RSI period
input double InpRsiOB         = 70.0;   // RSI overbought level -> allow SHORT fade
input double InpRsiOS         = 30.0;   // RSI oversold level   -> allow LONG fade
input bool   InpRequireRsi    = true;   // Require RSI extreme in addition to band poke

input group "Trend guard (do NOT fade a strong trend)"
input bool   InpUseTrendGuard = true;   // Block fades when a strong trend is running
input int    InpAdxPeriod     = 14;     // ADX period
input double InpAdxMax        = 30.0;   // Skip fades when ADX above this (strong trend = don't fade)

input group "Volatility gate"
input int    InpAtrPeriod     = 14;     // ATR period
input double InpAtrMinPips    = 4.0;    // Skip entries when ATR below this (dead market). 0 = off

input group "Exit / trade management"
input double InpStopAtrMult   = 1.5;    // Hard stop distance = ATR * this
input double InpBeTriggerR     = 1.0;   // Move to break-even once profit reaches this many R (0 = off)
input double InpBeLockPips      = 1.0;  // Lock this many pips when moving to break-even
input double InpTrailAtrMult    = 0.0;  // ATR trail after BE (0 = off; fades usually just take the TP)

input group "Filters"
input int    InpMaxSpreadPts  = 60;     // Skip entries when spread exceeds this (points). 0 = off
input bool   InpAvoidRollover = true;   // Skip entries around the daily close/rollover
input int    InpRolloverHour  = 23;     // Server hour to avoid
input bool   InpOneTradePerBar= true;   // At most one new entry per bar

input group "Engine"
input long   InpMagic         = 77022024; // Magic (DIFFERENT from breakout EA's 77012024)
input int    InpSlippage      = 30;       // Max deviation, points
input bool   InpShowPanel     = true;     // Draw the status panel
input bool   InpEnableLog     = true;     // Log to Experts tab
input bool   InpDebugSkips    = false;    // Log WHY no entry fired (once per bar)

//====================================================================
//  STATE
//====================================================================
CTrade   m_trade;
string   m_sym;
double   m_point;
int      m_digits;
int      g_ppp = 10;
int      hBB=INVALID_HANDLE, hRSI=INVALID_HANDLE, hATR=INVALID_HANDLE, hADX=INVALID_HANDLE;

datetime m_lastBar    = 0;
int      m_dayWins    = 0;
int      m_dayLosses  = 0;
double   m_dayStartBal= 0.0;
int      m_curDay     = -1;
bool     m_dayHalted  = false;
string   g_lastSkip   = "";

double   PtsToPips(double pts){ return pts / g_ppp; }
double   PipsToPts(double pips){ return pips * g_ppp; }
void     Log(const string s){ if(InpEnableLog) Print("[MRev] ", s); }
double   Ask(){ return SymbolInfoDouble(m_sym,SYMBOL_ASK); }
double   Bid(){ return SymbolInfoDouble(m_sym,SYMBOL_BID); }
double   Nz(double p){ return NormalizeDouble(p,m_digits); }

//====================================================================
//  INIT
//====================================================================
int OnInit()
  {
   m_sym    = _Symbol;
   m_point  = SymbolInfoDouble(m_sym,SYMBOL_POINT);
   m_digits = (int)SymbolInfoInteger(m_sym,SYMBOL_DIGITS);
   g_ppp    = (m_digits==3 || m_digits==5 || m_digits==2) ? 10 : 1;

   if(InpStopAtrMult<=0 || InpRiskMoney<=0)
     { Print("[MRev] stop mult and risk money must be > 0."); return INIT_PARAMETERS_INCORRECT; }

   hBB  = iBands(m_sym,_Period,InpBbPeriod,0,InpBbDev,PRICE_CLOSE);
   hRSI = iRSI(m_sym,_Period,InpRsiPeriod,PRICE_CLOSE);
   hATR = iATR(m_sym,_Period,InpAtrPeriod);
   hADX = iADX(m_sym,_Period,InpAdxPeriod);
   if(hBB==INVALID_HANDLE || hRSI==INVALID_HANDLE || hATR==INVALID_HANDLE || hADX==INVALID_HANDLE)
     { Print("[MRev] indicator handle failed."); return INIT_FAILED; }

   m_trade.SetExpertMagicNumber(InpMagic);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFillingBySymbol(m_sym);

   m_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); m_curDay=dt.day_of_year;

   if(InpShowPanel) PanelCreate();
   Log(StringFormat("init v1.0 risk(£)=%.2f R=%.2f stop=%.1fxATR BB %d/%.1f RSI %d [%.0f/%.0f] ADXmax=%.0f",
        InpRiskMoney,InpRewardRatio,InpStopAtrMult,InpBbPeriod,InpBbDev,InpRsiPeriod,InpRsiOS,InpRsiOB,InpAdxMax));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int r)
  {
   if(hBB!=INVALID_HANDLE)  IndicatorRelease(hBB);
   if(hRSI!=INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
   if(hADX!=INVALID_HANDLE) IndicatorRelease(hADX);
   PanelDestroy();
  }

//====================================================================
//  INDICATOR HELPERS
//====================================================================
double ATRnow(){ double b[]; if(CopyBuffer(hATR,0,0,1,b)<1)return 0; return b[0]; }
double RSInow(){ double b[]; if(CopyBuffer(hRSI,0,0,1,b)<1)return 0; return b[0]; }
double ADXnow(){ double b[]; if(CopyBuffer(hADX,0,0,1,b)<1)return 0; return b[0]; }   // buffer 0 = main ADX line
double BBupper(){ double b[]; if(CopyBuffer(hBB,1,0,1,b)<1)return 0; return b[0]; }    // buffer 1 = upper
double BBlower(){ double b[]; if(CopyBuffer(hBB,2,0,1,b)<1)return 0; return b[0]; }    // buffer 2 = lower
double BBmid()  { double b[]; if(CopyBuffer(hBB,0,0,1,b)<1)return 0; return b[0]; }    // buffer 0 = middle

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
double LotForRisk(double stopPoints)
  {
   double tickVal  = SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_SIZE);
   if(tickVal<=0 || tickSize<=0 || stopPoints<=0) return InpMinLot;
   double lossPerLot = (stopPoints*m_point/tickSize)*tickVal;
   if(lossPerLot<=0) return InpMinLot;
   double lot = InpRiskMoney / lossPerLot;
   double vmin=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MAX);
   double vstep=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_STEP);
   if(vstep>0) lot=MathFloor(lot/vstep)*vstep;
   lot=MathMax(lot,MathMax(vmin,InpMinLot));
   lot=MathMin(lot,MathMin(vmax,InpMaxLot));
   return NormalizeDouble(lot,2);
  }

//====================================================================
//  DAILY GUARD
//====================================================================
void RollDayIfNeeded()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(dt.day_of_year!=m_curDay)
     { m_curDay=dt.day_of_year; m_dayStartBal=AccountInfoDouble(ACCOUNT_BALANCE);
       m_dayWins=0; m_dayLosses=0; m_dayHalted=false; Log("new day: counters reset"); }
  }
double DayPL(){ return (AccountInfoDouble(ACCOUNT_BALANCE)-m_dayStartBal)+FloatingPL(); }
bool DailyHalted()
  {
   if(InpDailyLossStop<=0) return false;
   if(m_dayHalted) return true;
   if(DayPL() <= -InpDailyLossStop){ m_dayHalted=true; Log(StringFormat("DAILY LOSS STOP (%.2f)",DayPL())); return true; }
   return false;
  }

//====================================================================
//  FILTERS
//====================================================================
bool SpreadOK(){ if(InpMaxSpreadPts<=0)return true; return ((Ask()-Bid())/m_point)<=InpMaxSpreadPts; }
bool RolloverOK()
  {
   if(InpAvoidRollover){ MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); if(dt.hour==InpRolloverHour)return false; }
   long tm=SymbolInfoInteger(m_sym,SYMBOL_TRADE_MODE);
   if(tm==SYMBOL_TRADE_MODE_DISABLED || tm==SYMBOL_TRADE_MODE_CLOSEONLY) return false;
   return true;
  }
bool VolatilityOK(double atr)
  {
   double atrPips=PtsToPips(atr/m_point);
   if(InpAtrMinPips>0 && atrPips<InpAtrMinPips) return false;
   return true;
  }

//====================================================================
//  ENTRY (fade extremes; block in strong trends)
//====================================================================
//--- +1 long (fade down-extreme), -1 short (fade up-extreme), 0 none
int Signal()
  {
   double up=BBupper(), lo=BBlower();
   if(up<=0 || lo<=0){ g_lastSkip="bands not ready"; return 0; }

   //--- trend guard: strong trend => do NOT fade
   if(InpUseTrendGuard)
     { double adx=ADXnow();
       if(adx>InpAdxMax){ g_lastSkip=StringFormat("ADX %.0f > %.0f (trending, no fade)",adx,InpAdxMax); return 0; } }

   double rsi = RSInow();
   //--- SHORT fade: price poked above upper band + RSI overbought
   bool shortBand = (Bid() >= up);
   bool longBand  = (Ask() <= lo);
   bool shortRsi  = (!InpRequireRsi) || (rsi>=InpRsiOB);
   bool longRsi   = (!InpRequireRsi) || (rsi<=InpRsiOS);

   if(shortBand && shortRsi) return -1;
   if(longBand  && longRsi ) return +1;

   if(shortBand && !shortRsi)      g_lastSkip=StringFormat("upper band poke but RSI %.0f < %.0f",rsi,InpRsiOB);
   else if(longBand && !longRsi)   g_lastSkip=StringFormat("lower band poke but RSI %.0f > %.0f",rsi,InpRsiOS);
   else                            g_lastSkip="price inside bands";
   return 0;
  }

void TryEnter()
  {
   double atr=ATRnow();
   if(atr<=0){ g_lastSkip="ATR not ready"; return; }
   if(!VolatilityOK(atr)){ g_lastSkip=StringFormat("ATR gate %.1f<%.1f",PtsToPips(atr/m_point),InpAtrMinPips); return; }
   if(!SpreadOK()){ g_lastSkip="spread too wide"; return; }
   if(!RolloverOK()){ g_lastSkip="rollover/close window"; return; }

   int sig=Signal();
   if(sig==0) return;

   double stopDist=atr*InpStopAtrMult;
   double stopPts =stopDist/m_point;
   double lot     =LotForRisk(stopPts);

   double sl,tp,entry;
   if(sig>0)
     { entry=Ask(); sl=Nz(entry-stopDist); tp=Nz(entry+stopDist*InpRewardRatio);
       if(!m_trade.Buy(lot,m_sym,0,sl,tp,"MRev")){ Log(StringFormat("BUY failed rc=%u",m_trade.ResultRetcode())); return; }
       Log(StringFormat("LONG fade %.2f @%.*f SL=%.*f TP=%.*f (ATR=%.1fpip)",lot,m_digits,entry,m_digits,sl,m_digits,tp,PtsToPips(atr/m_point))); }
   else
     { entry=Bid(); sl=Nz(entry+stopDist); tp=Nz(entry-stopDist*InpRewardRatio);
       if(!m_trade.Sell(lot,m_sym,0,sl,tp,"MRev")){ Log(StringFormat("SELL failed rc=%u",m_trade.ResultRetcode())); return; }
       Log(StringFormat("SHORT fade %.2f @%.*f SL=%.*f TP=%.*f (ATR=%.1fpip)",lot,m_digits,entry,m_digits,sl,m_digits,tp,PtsToPips(atr/m_point))); }
  }

//====================================================================
//  TRADE MANAGEMENT: break-even + optional ATR trail (never widen)
//====================================================================
void ManageOpen()
  {
   double atr=ATRnow();
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i); if(t==0)continue;
      if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
      bool lng=((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL), tp=PositionGetDouble(POSITION_TP);
      double cur=lng?Bid():Ask();
      double riskDist=MathAbs(entry-sl); if(riskDist<=0) riskDist=atr*InpStopAtrMult;
      double profDist=lng?(cur-entry):(entry-cur);
      double rMult=(riskDist>0)?profDist/riskDist:0;
      double newSL=sl;

      if(InpBeTriggerR>0 && rMult>=InpBeTriggerR)
        { double lock=InpBeLockPips*PipsToPts(1.0)*m_point;
          double be=lng?Nz(entry+lock):Nz(entry-lock);
          if(lng && sl<be) newSL=be;
          if(!lng && (sl>be||sl==0)) newSL=be; }

      if(InpTrailAtrMult>0 && rMult>=InpBeTriggerR && atr>0)
        { double trail=atr*InpTrailAtrMult;
          double cand=lng?Nz(cur-trail):Nz(cur+trail);
          if(lng && cand>newSL) newSL=cand;
          if(!lng && (cand<newSL||newSL==0)) newSL=cand; }

      bool improve=lng?(newSL>sl):(newSL<sl||sl==0);
      if(improve && MathAbs(newSL-sl)>=m_point)
         if(m_trade.PositionModify(t,newSL,tp))
            Log(StringFormat("%s trail SL %.*f->%.*f (R=%.2f)",lng?"LONG":"SHORT",m_digits,sl,m_digits,newSL,rMult));
     }
  }

//====================================================================
//  TALLY
//====================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &req,const MqlTradeResult &res)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   ulong tk=trans.deal;
   if(tk==0 || !HistoryDealSelect(tk)) return;
   if(HistoryDealGetInteger(tk,DEAL_MAGIC)!=InpMagic) return;
   if(HistoryDealGetString(tk,DEAL_SYMBOL)!=m_sym) return;
   if(HistoryDealGetInteger(tk,DEAL_ENTRY)!=DEAL_ENTRY_OUT) return;
   double pl=HistoryDealGetDouble(tk,DEAL_PROFIT)+HistoryDealGetDouble(tk,DEAL_SWAP)+HistoryDealGetDouble(tk,DEAL_COMMISSION);
   if(pl>=0) m_dayWins++; else m_dayLosses++;
  }

//====================================================================
//  MAIN
//====================================================================
void OnTick()
  {
   RollDayIfNeeded();
   ManageOpen();
   PanelUpdate();

   datetime bt=iTime(m_sym,_Period,0);
   bool newBar=(bt!=m_lastBar);
   if(InpOneTradePerBar && !newBar) return;
   if(newBar) m_lastBar=bt;

   if(DailyHalted()){ if(InpDebugSkips&&newBar)Log("skip: daily halt"); return; }
   if(MyPositions()>0){ if(InpDebugSkips&&newBar)Log("skip: in position"); return; }

   g_lastSkip="";
   TryEnter();
   if(InpDebugSkips && newBar && g_lastSkip!="") Log("skip: "+g_lastSkip);
  }

//====================================================================
//  STATUS PANEL
//====================================================================
#define MR "MR_"
color PC_BG=C'20,18,26', PC_GOLD=C'214,175,55', PC_TXT=C'230,232,238',
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
   int x=350,y=22,w=320,h=132;   // offset right so it doesn't overlap the breakout panel
   pRect(MR"bg",x,y,w,h,PC_BG);
   pLbl(MR"ttl",x+10,y+8,"MeanReversion (fade)",PC_GOLD,11,true);
  }
void PanelDestroy(){ ObjectsDeleteAll(0,MR); }
void PanelUpdate()
  {
   if(!InpShowPanel) return;
   double atr=ATRnow(), adx=ADXnow(), rsi=RSInow();
   double dpl=DayPL();
   string pos="Position: flat";
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       bool lng=((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
       pos=StringFormat("Position: %s %.2f  P/L=%.2f",lng?"LONG":"SHORT",PositionGetDouble(POSITION_VOLUME),PositionGetDouble(POSITION_PROFIT));
       break; }
   int bx=350;
   pLbl(MR"l1",bx+10,44,StringFormat("RSI: %.0f   ADX: %.0f %s",rsi,adx,(InpUseTrendGuard&&adx>InpAdxMax)?"(no fade)":""),PC_TXT,9);
   pLbl(MR"l2",bx+10,62,StringFormat("ATR: %.1f pip",PtsToPips(atr/m_point)),PC_TXT,9);
   pLbl(MR"l3",bx+10,80,pos,PC_TXT,9);
   pLbl(MR"l4",bx+10,98,StringFormat("Day P/L: %.2f  (limit -%.0f)",dpl,InpDailyLossStop),dpl>=0?PC_GRN:PC_RED,9);
   pLbl(MR"l5",bx+10,116,StringFormat("Wins: %d  Losses: %d",m_dayWins,m_dayLosses),PC_MUTE,9);
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
