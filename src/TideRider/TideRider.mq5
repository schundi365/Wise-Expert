//+------------------------------------------------------------------+
//|                                                   TideRider.mq5   |
//|   Trend RIDER - the professional trend-following template.       |
//|                                                                  |
//|   "Ride the tide": cut losers fast, let winners run enormously,  |
//|   and add to winners as the trend proves itself.                 |
//|                                                                  |
//|   IDEA 1 (basket): single-symbol EA, but designed to be run      |
//|     across MANY markets at once. Trend-following is a PORTFOLIO  |
//|     strategy - a few huge winners across many symbols pay for    |
//|     the many small losers. Judged on the AGGREGATE, not one pair.|
//|   IDEA 2 (asymmetric exit): hard 1R stop, NO fixed take-profit.  |
//|     A wide ATR trailing stop lets a winner run 5R, 10R, 20R until|
//|     the trend breaks. Low win rate is EXPECTED and fine.         |
//|   IDEA 3 (pyramiding): add to a winner each time it advances     |
//|     another +InpAddStepR, up to InpMaxAdds. Every add's stop is  |
//|     trailed so TOTAL open risk stays capped. This is the SAFE,   |
//|     correct inverse of the grid: add to WINNERS, never losers.   |
//|                                                                  |
//|   SAFETY: every position has a hard stop; the trail only ever    |
//|   tightens; a trend reversal closes the whole stack via stops.   |
//+------------------------------------------------------------------+
#property copyright "WiseTrader"
#property version   "1.00"
#property strict
#property description "Trend rider (ideas 1+2+3): cut losers at 1R, let winners run uncapped on a wide ATR trail, pyramid into confirmed trends. Run across a basket of markets; judge the aggregate."

#include <Trade/Trade.mqh>

//====================================================================
//  INPUTS
//====================================================================
input group "Risk (per initial entry)"
input double InpRiskMoney     = 10.0;   // Risk of the FIRST entry in account currency (£)
input double InpDailyLossStop = 150.0;  // Halt NEW entries for the day if P/L <= -this (0 = off)
input double InpMaxLot        = 2.00;   // Hard cap on a single order's lot
input double InpMinLot        = 0.01;   // Floor lot size

input group "Entry: Donchian breakout + EMA trend"
input int    InpDonchianBars  = 20;     // Enter on break of this many bars' high/low
input int    InpBufferPoints  = 30;     // Break must exceed the level by this many points
input int    InpEmaFast       = 50;     // Fast trend EMA
input int    InpEmaSlow       = 200;    // Slow trend EMA
input bool   InpUseEmaStack   = true;   // Require price/EMA stack agreement
input bool   InpUseEmaSlope   = true;   // Require fast EMA sloping in trade direction

input group "Exit (asymmetric: cut losers, ride winners)"
input int    InpAtrPeriod     = 14;     // ATR period
input double InpStopAtrMult   = 2.0;    // Initial hard stop = ATR * this (this is 1R)
input double InpTrailAtrMult   = 4.0;   // Wide ATR trailing stop (ride the tide). Tighten-only.
input double InpBeTriggerR      = 1.0;  // Arm the trail / move to BE once first entry is +this R

input group "Pyramiding (add to winners - idea 3)"
input bool   InpPyramid       = true;   // Add to winners as the trend advances
input double InpAddStepR       = 1.0;   // Add another unit each time price advances this many R
input int    InpMaxAdds        = 3;     // Max pyramid adds (beyond the initial entry)
input double InpAddRiskFrac     = 1.0;  // Each add risks this fraction of InpRiskMoney (1.0 = same size)

input group "Filters"
input int    InpMaxSpreadPts  = 100;    // Skip entries when spread exceeds this (points). 0 = off
input bool   InpAvoidRollover = true;   // Skip entries around the daily close/rollover
input int    InpRolloverHour  = 23;     // Server hour to avoid

input group "Engine"
input long   InpMagic         = 77042024; // Magic (distinct)
input int    InpSlippage      = 40;       // Max deviation, points
input bool   InpShowPanel     = true;     // Draw the status panel
input bool   InpEnableLog     = true;     // Log to Experts tab

//====================================================================
//  STATE
//====================================================================
CTrade   m_trade;
string   m_sym;
double   m_point;
int      m_digits;
int      g_ppp = 10;
int      hATR=INVALID_HANDLE, hEmaF=INVALID_HANDLE, hEmaS=INVALID_HANDLE;

datetime m_lastBar    = 0;
double   m_dayStartBal= 0.0;
int      m_curDay     = -1;
bool     m_dayHalted  = false;

//--- per-open-cycle pyramiding state
double   m_riskDist   = 0;   // 1R price distance for the current cycle (set on first entry)
double   m_firstEntry = 0;   // price of the first entry in the current cycle
int      m_addsDone   = 0;   // pyramid adds done in the current cycle
int      m_cycleDir   = 0;   // +1 long cycle, -1 short cycle, 0 flat

double   PtsToPips(double pts){ return pts / g_ppp; }
void     Log(const string s){ if(InpEnableLog) Print("[Tide] ", s); }
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
     { Print("[Tide] stop mult and risk money must be > 0."); return INIT_PARAMETERS_INCORRECT; }

   hATR  = iATR(m_sym,_Period,InpAtrPeriod);
   hEmaF = iMA(m_sym,_Period,InpEmaFast,0,MODE_EMA,PRICE_CLOSE);
   hEmaS = iMA(m_sym,_Period,InpEmaSlow,0,MODE_EMA,PRICE_CLOSE);
   if(hATR==INVALID_HANDLE || hEmaF==INVALID_HANDLE || hEmaS==INVALID_HANDLE)
     { Print("[Tide] indicator handle failed."); return INIT_FAILED; }

   m_trade.SetExpertMagicNumber(InpMagic);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFillingBySymbol(m_sym);

   m_dayStartBal=AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); m_curDay=dt.day_of_year;

   if(InpShowPanel) PanelCreate();
   Log(StringFormat("init v1.0 TF=%s risk(£)=%.2f stop=%.1fxATR trail=%.1fxATR pyramid=%s maxAdds=%d",
        EnumToString(_Period),InpRiskMoney,InpStopAtrMult,InpTrailAtrMult,InpPyramid?"ON":"off",InpMaxAdds));
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
//  HELPERS
//====================================================================
double ATRnow(){ double b[]; if(CopyBuffer(hATR,0,0,1,b)<1)return 0; return b[0]; }
double EmaFast(int sh=0){ double b[]; if(CopyBuffer(hEmaF,0,sh,1,b)<1)return 0; return b[0]; }
double EmaSlow(int sh=0){ double b[]; if(CopyBuffer(hEmaS,0,sh,1,b)<1)return 0; return b[0]; }
double DonHigh(int bars){ int i=iHighest(m_sym,_Period,MODE_HIGH,bars,1); return (i<0)?0:iHigh(m_sym,_Period,i); }
double DonLow (int bars){ int i=iLowest (m_sym,_Period,MODE_LOW ,bars,1); return (i<0)?0:iLow (m_sym,_Period,i); }

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
double LotForRisk(double stopPoints,double riskMoney)
  {
   double tickVal=SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_SIZE);
   //--- SAFETY: bad/zero specs -> refuse (0 lot = no trade), never guess.
   if(tickVal<=0 || tickSize<=0 || stopPoints<=0){ Log("size: bad symbol specs, skipping"); return 0; }
   double lossPerLot=(stopPoints*m_point/tickSize)*tickVal;
   if(lossPerLot<=0){ Log("size: non-positive loss/lot, skipping"); return 0; }

   double lot=riskMoney/lossPerLot;
   double vmin=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MAX);
   double vstep=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_STEP);
   if(vstep>0) lot=MathFloor(lot/vstep)*vstep;
   lot=MathMax(lot,MathMax(vmin,InpMinLot));
   lot=MathMin(lot,MathMin(vmax,InpMaxLot));
   lot=NormalizeDouble(lot,2);

   //--- HARD RISK CEILING: this was the XAUGBP bug. If the smallest allowed
   //--- lot still risks more than 3x the intended money (e.g. broker min lot
   //--- too big for this account/stop, or an odd contract spec), REFUSE the
   //--- trade entirely rather than silently taking oversized risk.
   double actualRisk = lot*lossPerLot;
   double ceiling    = 3.0*riskMoney;
   if(actualRisk > ceiling)
     { Log(StringFormat("size: min lot %.2f would risk £%.2f > ceiling £%.2f on %s - REFUSING trade",
            lot,actualRisk,ceiling,m_sym));
       return 0; }
   return lot;
  }

//====================================================================
//  DAILY GUARD
//====================================================================
void RollDayIfNeeded()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(dt.day_of_year!=m_curDay)
     { m_curDay=dt.day_of_year; m_dayStartBal=AccountInfoDouble(ACCOUNT_BALANCE); m_dayHalted=false; }
  }
double DayPL(){ return (AccountInfoDouble(ACCOUNT_BALANCE)-m_dayStartBal)+FloatingPL(); }
bool DailyHalted()
  {
   if(InpDailyLossStop<=0) return false;
   if(m_dayHalted) return true;
   if(DayPL()<=-InpDailyLossStop){ m_dayHalted=true; Log(StringFormat("DAILY LOSS STOP (%.2f)",DayPL())); return true; }
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

//====================================================================
//  ENTRY
//====================================================================
int TrendSignal()
  {
   double hi=DonHigh(InpDonchianBars), lo=DonLow(InpDonchianBars);
   if(hi<=0 || lo<=0) return 0;
   double buf=InpBufferPoints*m_point;
   double ef=EmaFast(), es=EmaSlow(), ef1=EmaFast(1);
   bool trendUp=true, trendDn=true;
   if(InpUseEmaStack){ trendUp=(ef>es && Bid()>ef); trendDn=(ef<es && Ask()<ef); }
   if(InpUseEmaSlope){ trendUp=trendUp && (ef>ef1); trendDn=trendDn && (ef<ef1); }
   if(Ask()>hi+buf && trendUp) return +1;
   if(Bid()<lo-buf && trendDn) return -1;
   return 0;
  }

//--- open the FIRST entry of a new cycle
void OpenFirst(int dir,double atr)
  {
   double stopDist=atr*InpStopAtrMult;
   double lot=LotForRisk(stopDist/m_point,InpRiskMoney);
   if(lot<=0) return;                 // sizing refused (unsafe on this symbol)
   double entry,sl;
   bool ok;
   if(dir>0){ entry=Ask(); sl=Nz(entry-stopDist); ok=m_trade.Buy (lot,m_sym,0,sl,0,"Tide"); }
   else     { entry=Bid(); sl=Nz(entry+stopDist); ok=m_trade.Sell(lot,m_sym,0,sl,0,"Tide"); }
   if(!ok){ Log(StringFormat("open failed rc=%u",m_trade.ResultRetcode())); return; }
   m_riskDist=stopDist; m_firstEntry=entry; m_addsDone=0; m_cycleDir=dir;
   Log(StringFormat("%s ENTRY %.2f @%.*f SL=%.*f (1R=%.*f)",dir>0?"LONG":"SHORT",lot,m_digits,entry,m_digits,sl,m_digits,stopDist));
  }

//--- add a pyramid unit in the trend direction
void AddUnit(double atr)
  {
   double stopDist=atr*InpStopAtrMult;
   double lot=LotForRisk(stopDist/m_point,InpRiskMoney*InpAddRiskFrac);
   if(lot<=0) return;                 // sizing refused
   double entry,sl; bool ok;
   if(m_cycleDir>0){ entry=Ask(); sl=Nz(entry-stopDist); ok=m_trade.Buy (lot,m_sym,0,sl,0,"TideAdd"); }
   else            { entry=Bid(); sl=Nz(entry+stopDist); ok=m_trade.Sell(lot,m_sym,0,sl,0,"TideAdd"); }
   if(!ok){ Log(StringFormat("add failed rc=%u",m_trade.ResultRetcode())); return; }
   m_addsDone++;
   Log(StringFormat("PYRAMID add #%d %s %.2f @%.*f",m_addsDone,m_cycleDir>0?"LONG":"SHORT",lot,m_digits,entry));
  }

//====================================================================
//  MANAGE: trail ALL positions together (tighten-only) + pyramid
//====================================================================
void ManageCycle()
  {
   int n=MyPositions();
   if(n==0){ m_cycleDir=0; m_addsDone=0; m_riskDist=0; return; }   // cycle ended (stopped out)

   double atr=ATRnow();
   double cur = (m_cycleDir>0)? Bid() : Ask();

   //--- how far the trend has advanced from the FIRST entry, in R
   double advDist = (m_cycleDir>0)? (cur-m_firstEntry) : (m_firstEntry-cur);
   double advR    = (m_riskDist>0)? advDist/m_riskDist : 0;

   //--- IDEA 3: pyramid. Add when advance passes the next add threshold.
   if(InpPyramid && m_addsDone<InpMaxAdds && atr>0)
     {
      double nextThresh = (m_addsDone+1)*InpAddStepR;   // +1R, +2R, ...
      if(advR >= nextThresh) AddUnit(atr);
     }

   //--- IDEA 2: wide trailing stop, applied to EVERY open position, tighten-only.
   if(atr>0 && advR>=InpBeTriggerR)
     {
      double trail=atr*InpTrailAtrMult;
      double newSL = (m_cycleDir>0)? Nz(cur-trail) : Nz(cur+trail);
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong t=PositionGetTicket(i); if(t==0)continue;
         if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
         if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
         double sl=PositionGetDouble(POSITION_SL);
         double tp=PositionGetDouble(POSITION_TP);
         bool improve = (m_cycleDir>0)? (newSL>sl) : (newSL<sl || sl==0);
         if(improve && MathAbs(newSL-sl)>=m_point)
            m_trade.PositionModify(t,newSL,tp);
        }
     }
  }

//====================================================================
//  MAIN
//====================================================================
void OnTick()
  {
   RollDayIfNeeded();
   ManageCycle();
   PanelUpdate();

   datetime bt=iTime(m_sym,_Period,0);
   bool newBar=(bt!=m_lastBar);
   if(!newBar) return;
   m_lastBar=bt;

   if(DailyHalted()) return;

   //--- only look for a NEW cycle when flat; adds happen in ManageCycle
   if(MyPositions()>0) return;

   double atr=ATRnow();
   if(atr<=0 || !SpreadOK() || !RolloverOK()) return;
   int sig=TrendSignal();
   if(sig!=0) OpenFirst(sig,atr);
  }

//====================================================================
//  STATUS PANEL
//====================================================================
#define TR "TR_"
color PT_BG=C'16,22,28', PT_GOLD=C'214,175,55', PT_TXT=C'230,232,238',
      PT_GRN=C'0,170,80', PT_RED=C'210,60,66', PT_MUTE=C'150,160,175';
void pLbl(string n,int x,int y,string t,color c,int fs=9,bool b=false)
  {
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetString (0,n,OBJPROP_TEXT,t); ObjectSetString(0,n,OBJPROP_FONT,b?"Arial Bold":"Consolas");
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
   ObjectSetInteger(0,n,OBJPROP_COLOR,PT_GOLD); ObjectSetInteger(0,n,OBJPROP_BACK,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }
void PanelCreate(){ pRect(TR"bg",10,22,320,120,PT_BG); pLbl(TR"ttl",20,30,StringFormat("TideRider (%s)",EnumToString(_Period)),PT_GOLD,11,true); }
void PanelDestroy(){ ObjectsDeleteAll(0,TR); }
void PanelUpdate()
  {
   if(!InpShowPanel) return;
   double atr=ATRnow(); double ef=EmaFast(), es=EmaSlow();
   string trend=(ef>es)?"UP":"DOWN";
   double dpl=DayPL();
   string cyc = (m_cycleDir==0)?"flat":StringFormat("%s  units=%d  adds=%d",m_cycleDir>0?"LONG":"SHORT",MyPositions(),m_addsDone);
   pLbl(TR"l1",24,56,StringFormat("Trend: %s   ATR: %.0f pt",trend,atr/m_point),PT_TXT,9);
   pLbl(TR"l2",24,76,"Cycle: "+cyc,PT_TXT,9);
   pLbl(TR"l3",24,96,StringFormat("Floating P/L: %.2f",FloatingPL()),FloatingPL()>=0?PT_GRN:PT_RED,9);
   pLbl(TR"l4",24,116,StringFormat("Day P/L: %.2f  (limit -%.0f)",dpl,InpDailyLossStop),dpl>=0?PT_GRN:PT_RED,9);
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
