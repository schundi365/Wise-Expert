//+------------------------------------------------------------------+
//|                                                 SessionEdge.mq5   |
//|   Opening Range Breakout (ORB) - a STRUCTURAL/time-of-day edge.   |
//|                                                                  |
//|   Theory (why this is different from the 7 that failed):         |
//|   The prior 7 EAs were price-PATTERN bets ("this shape => price   |
//|   goes my way"). Those are the most arbitraged edges and none     |
//|   survived real ticks.                                            |
//|   ORB instead exploits a STRUCTURAL fact: at a major session open |
//|   (London / New York), real institutional liquidity floods in and |
//|   price frequently breaks the pre-session range in the direction  |
//|   of the day's genuine order flow. The edge is tied to WHEN money |
//|   actually trades, not to a chart shape.                          |
//|                                                                  |
//|   MECHANICS: define an opening range over the first InpRangeMins  |
//|   after InpSessionHour. On a break of that range (+ buffer), enter|
//|   with a HARD stop (the opposite side of the range, or ATR) and a |
//|   fixed R target. One trade per session. Flatten by InpFlatHour.  |
//|   All the safety guards (risk ceiling, rollover) carried over.    |
//+------------------------------------------------------------------+
#property copyright "WiseTrader"
#property version   "1.00"
#property strict
#property description "Opening Range Breakout: a structural session/time-of-day edge. Break of the session opening range, hard stop, R target, flat by session end. Different in kind from price-pattern EAs."

#include <Trade/Trade.mqh>

//====================================================================
//  INPUTS
//====================================================================
input group "Risk"
input double InpRiskMoney     = 10.0;   // Risk PER TRADE in account currency (£)
input double InpRewardRatio   = 1.5;    // Take-profit as a multiple of risk
input double InpMaxLot        = 1.00;   // Hard cap on lot size
input double InpMinLot        = 0.01;   // Floor lot size

input group "Session / Opening Range"
input int    InpSessionHour   = 8;      // Session start HOUR (server time) - range begins here
input int    InpRangeMins     = 60;     // Opening-range window length in minutes
input int    InpFlatHour      = 20;     // Force-flat hour (close any open trade by this hour)
input int    InpBufferPoints  = 20;     // Break must exceed the range edge by this many points
input bool   InpOneTradePerDay= true;   // At most one ORB trade per session/day

input group "Stop"
input bool   InpStopFromRange = true;   // true = stop at opposite range edge; false = ATR stop
input int    InpAtrPeriod     = 14;     // ATR period (used if InpStopFromRange=false)
input double InpStopAtrMult   = 1.5;    // ATR stop multiple (if not using range stop)
input double InpBeTriggerR      = 1.0;  // Move to break-even once +this many R (0 = off)

input group "Filters"
input int    InpMaxSpreadPts  = 60;     // Skip if spread exceeds this (points). 0 = off
input bool   InpAvoidRollover = true;   // Skip around daily close/rollover
input int    InpRolloverHour  = 23;     // Server hour to avoid

input group "Engine"
input long   InpMagic         = 77052024; // Magic (distinct)
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
int      hATR=INVALID_HANDLE;

int      m_curDay     = -1;      // day-of-year of the current session
bool     m_rangeDone  = false;   // opening range finalized for today
bool     m_tradedToday= false;   // an ORB trade fired today
double   m_rangeHi    = 0;       // opening-range high
double   m_rangeLo    = 0;       // opening-range low

void     Log(const string s){ if(InpEnableLog) Print("[ORB] ", s); }
double   Ask(){ return SymbolInfoDouble(m_sym,SYMBOL_ASK); }
double   Bid(){ return SymbolInfoDouble(m_sym,SYMBOL_BID); }
double   Nz(double p){ return NormalizeDouble(p,m_digits); }

//====================================================================
//  INIT
//====================================================================
int OnInit()
  {
   m_sym=_Symbol; m_point=SymbolInfoDouble(m_sym,SYMBOL_POINT);
   m_digits=(int)SymbolInfoInteger(m_sym,SYMBOL_DIGITS);
   if(InpRiskMoney<=0){ Print("[ORB] risk must be > 0"); return INIT_PARAMETERS_INCORRECT; }
   hATR=iATR(m_sym,_Period,InpAtrPeriod);
   m_trade.SetExpertMagicNumber(InpMagic);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFillingBySymbol(m_sym);
   if(InpShowPanel) PanelCreate();
   Log(StringFormat("init v1.0 session=%02d:00 range=%dmin R=%.1f risk(£)=%.2f",InpSessionHour,InpRangeMins,InpRewardRatio,InpRiskMoney));
   return INIT_SUCCEEDED;
  }
void OnDeinit(const int r){ if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR); PanelDestroy(); }

//====================================================================
//  HELPERS
//====================================================================
double ATRnow(){ double b[]; if(CopyBuffer(hATR,0,0,1,b)<1)return 0; return b[0]; }
int MyPositions()
  {
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue; n++; }
   return n;
  }
double LotForRisk(double stopPoints)
  {
   double tv=SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0 || ts<=0 || stopPoints<=0) return 0;
   double lossPerLot=(stopPoints*m_point/ts)*tv;
   if(lossPerLot<=0) return 0;
   double lot=InpRiskMoney/lossPerLot;
   double vmin=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MAX);
   double vstep=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_STEP);
   if(vstep>0) lot=MathFloor(lot/vstep)*vstep;
   lot=MathMax(lot,MathMax(vmin,InpMinLot));
   lot=MathMin(lot,MathMin(vmax,InpMaxLot));
   lot=NormalizeDouble(lot,2);
   if(lot*lossPerLot > 3.0*InpRiskMoney) return 0;   // risk-ceiling safety
   return lot;
  }
bool SpreadOK(){ if(InpMaxSpreadPts<=0)return true; return ((Ask()-Bid())/m_point)<=InpMaxSpreadPts; }
bool RolloverOK()
  {
   if(InpAvoidRollover){ MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); if(dt.hour==InpRolloverHour)return false; }
   long tm=SymbolInfoInteger(m_sym,SYMBOL_TRADE_MODE);
   if(tm==SYMBOL_TRADE_MODE_DISABLED || tm==SYMBOL_TRADE_MODE_CLOSEONLY) return false;
   return true;
  }

//--- build the opening range from the bars inside [SessionHour, +RangeMins]
void ComputeOpeningRange()
  {
   datetime now=TimeCurrent();
   MqlDateTime dt; TimeToStruct(now,dt);
   //--- start of today's session window
   MqlDateTime s=dt; s.hour=InpSessionHour; s.min=0; s.sec=0;
   datetime rangeStart=StructToTime(s);
   datetime rangeEnd  =rangeStart + InpRangeMins*60;
   if(now < rangeEnd){ m_rangeDone=false; return; }   // range still forming

   //--- scan bars between rangeStart and rangeEnd for hi/lo
   double hi=-DBL_MAX, lo=DBL_MAX; bool any=false;
   for(int i=0;i<500;i++)
     {
      datetime bt=iTime(m_sym,_Period,i);
      if(bt==0) break;
      if(bt<rangeStart) break;         // gone past the window (bars are newest-first)
      if(bt>=rangeEnd) continue;       // bar after the range window
      double bh=iHigh(m_sym,_Period,i), bl=iLow(m_sym,_Period,i);
      if(bh>hi) hi=bh;
      if(bl<lo) lo=bl;
      any=true;
     }
   if(any){ m_rangeHi=hi; m_rangeLo=lo; m_rangeDone=true; }
  }

//====================================================================
//  MAIN
//====================================================================
void OnTick()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);

   //--- new day: reset session state
   if(dt.day_of_year!=m_curDay)
     { m_curDay=dt.day_of_year; m_rangeDone=false; m_tradedToday=false; m_rangeHi=0; m_rangeLo=0; }

   //--- manage break-even for an open trade
   ManageOpen();
   PanelUpdate();

   //--- force flat at/after the flat hour
   if(dt.hour>=InpFlatHour){ if(MyPositions()>0) CloseAll("session flat"); return; }

   //--- only act during the session, after the opening range completes
   if(dt.hour<InpSessionHour) return;
   if(!m_rangeDone) ComputeOpeningRange();
   if(!m_rangeDone) return;
   if(m_tradedToday && InpOneTradePerDay) return;
   if(MyPositions()>0) return;
   if(!SpreadOK() || !RolloverOK()) return;

   double buf=InpBufferPoints*m_point;
   int dir=0;
   if(Ask() > m_rangeHi+buf) dir=+1;
   else if(Bid() < m_rangeLo-buf) dir=-1;
   if(dir==0) return;

   //--- stop: opposite range edge (structural) or ATR
   double entry = (dir>0)? Ask() : Bid();
   double stopDist;
   if(InpStopFromRange)
      stopDist = (dir>0)? (entry - m_rangeLo) : (m_rangeHi - entry);
   else
      stopDist = ATRnow()*InpStopAtrMult;
   if(stopDist<=0){ stopDist=ATRnow()*InpStopAtrMult; }
   if(stopDist<=0) return;

   double lot=LotForRisk(stopDist/m_point);
   if(lot<=0){ Log("sizing refused"); return; }

   double sl,tp; bool ok;
   if(dir>0){ sl=Nz(entry-stopDist); tp=Nz(entry+stopDist*InpRewardRatio); ok=m_trade.Buy(lot,m_sym,0,sl,tp,"ORB"); }
   else     { sl=Nz(entry+stopDist); tp=Nz(entry-stopDist*InpRewardRatio); ok=m_trade.Sell(lot,m_sym,0,sl,tp,"ORB"); }
   if(ok){ m_tradedToday=true; Log(StringFormat("%s ORB %.2f @%.*f SL=%.*f TP=%.*f (range %.*f-%.*f)",
            dir>0?"LONG":"SHORT",lot,m_digits,entry,m_digits,sl,m_digits,tp,m_digits,m_rangeLo,m_digits,m_rangeHi)); }
   else Log(StringFormat("ORB entry failed rc=%u",m_trade.ResultRetcode()));
  }

//--- break-even management
void ManageOpen()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i); if(t==0)continue;
      if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
      if(InpBeTriggerR<=0) continue;
      bool lng=((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN), sl=PositionGetDouble(POSITION_SL), tp=PositionGetDouble(POSITION_TP);
      double cur=lng?Bid():Ask();
      double riskDist=MathAbs(entry-sl); if(riskDist<=0) continue;
      double profDist=lng?(cur-entry):(entry-cur);
      if(profDist >= InpBeTriggerR*riskDist)
        {
         double be = lng? Nz(entry+2*m_point) : Nz(entry-2*m_point);
         bool improve = lng? (sl<be) : (sl>be || sl==0);
         if(improve) m_trade.PositionModify(t,be,tp);
        }
     }
  }
void CloseAll(const string why)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       m_trade.PositionClose(t); }
   if(why!="") Log("close all: "+why);
  }

//====================================================================
//  PANEL
//====================================================================
#define OR "ORB_"
color O_BG=C'20,22,18', O_GOLD=C'214,175,55', O_TXT=C'230,232,238', O_GRN=C'0,170,80', O_RED=C'210,60,66';
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
   ObjectSetInteger(0,n,OBJPROP_COLOR,O_GOLD); ObjectSetInteger(0,n,OBJPROP_BACK,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }
void PanelCreate(){ pRect(OR"bg",10,22,320,96,O_BG); pLbl(OR"ttl",20,30,StringFormat("SessionEdge ORB (%s)",EnumToString(_Period)),O_GOLD,11,true); }
void PanelDestroy(){ ObjectsDeleteAll(0,OR); }
void PanelUpdate()
  {
   if(!InpShowPanel) return;
   string rng = m_rangeDone? StringFormat("%.*f - %.*f",m_digits,m_rangeLo,m_digits,m_rangeHi) : "forming...";
   pLbl(OR"l1",24,54,"Opening range: "+rng,O_TXT,9);
   pLbl(OR"l2",24,74,StringFormat("Traded today: %s   Open: %d",m_tradedToday?"yes":"no",MyPositions()),O_TXT,9);
   double fp=0; for(int i=PositionsTotal()-1;i>=0;i--){ ulong t=PositionGetTicket(i); if(t==0)continue; if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue; if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue; fp+=PositionGetDouble(POSITION_PROFIT); }
   pLbl(OR"l3",24,94,StringFormat("Floating P/L: %.2f",fp),fp>=0?O_GRN:O_RED,9);
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
