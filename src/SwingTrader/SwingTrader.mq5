//+------------------------------------------------------------------+
//|                                                 SwingTrader.mq5   |
//|   Higher-timeframe (H1/H4) trend-following swing EA.             |
//|                                                                  |
//|   WHY HIGHER TIMEFRAME: on M5 gold the spread/cost is large      |
//|   relative to the moves, so any edge gets eaten (our real-tick   |
//|   tests kept collapsing toward break-even). On H1/H4 the moves   |
//|   are 10-20x bigger while the spread is the SAME - so a genuine  |
//|   edge can actually clear costs. Same disciplined framework,     |
//|   moved to where the math works.                                 |
//|                                                                  |
//|   STRATEGY: trade WITH the higher-timeframe trend, enter on a    |
//|   Donchian channel breakout (new N-bar high/low) confirmed by an |
//|   EMA-stack trend filter. Ride the swing with an ATR trail.      |
//|                                                                  |
//|   SAFETY (identical philosophy to MomentumScalper):             |
//|   - HARD stop on every trade (ATR based). Nothing floats free.   |
//|   - Reward:risk >= 1.5. Wins bigger than losses.                 |
//|   - Fixed MONEY risk per trade -> constant risk sizing.          |
//|   - Break-even at +1R, then ATR trail to let winners run.        |
//|   - Daily loss stop, spread guard, rollover guard.               |
//+------------------------------------------------------------------+
#property copyright "WiseTrader"
#property version   "1.00"
#property strict
#property description "Higher-timeframe (H1/H4) trend-following swing EA: Donchian breakout + EMA trend filter, hard ATR stop, R>=1.5, BE+ATR trail. Moves the disciplined framework to where moves dwarf the spread."

#include <Trade/Trade.mqh>

//====================================================================
//  INPUTS
//====================================================================
input group "Risk"
input double InpRiskMoney     = 10.0;   // Risk PER TRADE in account currency (£)
input double InpRewardRatio   = 2.0;    // TP as a multiple of risk (swings target big R). >= 1.5.
input double InpDailyLossStop = 100.0;  // Halt NEW trades for the day if P/L <= -this (0 = off)
input double InpMaxLot        = 1.00;   // Hard cap on lot size
input double InpMinLot        = 0.01;   // Floor lot size

input group "Entry: Donchian breakout + EMA trend filter"
input int    InpDonchianBars  = 20;     // Enter on a break of this many bars' high/low (Donchian channel)
input int    InpBufferPoints  = 30;     // Break must exceed the level by this many points
input int    InpEmaFast       = 50;     // Fast trend EMA
input int    InpEmaSlow       = 200;    // Slow trend EMA
input bool   InpUseEmaStack   = true;   // Require price/EMA stack agreement with breakout direction
input bool   InpUseEmaSlope   = true;   // Also require the fast EMA to be sloping in the trade direction

input group "Volatility gate"
input int    InpAtrPeriod     = 14;     // ATR period
input double InpAtrMinPips    = 0.0;    // Skip if ATR below this (0 = off; H1 ATR is naturally large)

input group "Exit / trade management"
input double InpStopAtrMult   = 2.0;    // Hard stop distance = ATR * this (wider on H1)
input double InpBeTriggerR      = 1.0;  // Move to break-even at this many R (0 = off)
input double InpBeLockPips       = 2.0; // Lock this many pips at break-even
input double InpTrailAtrMult     = 3.0; // ATR trail after BE (0 = off). Wide, to ride swings.

input group "Filters"
input int    InpMaxSpreadPts  = 80;     // Skip entries when spread exceeds this (points). 0 = off
input bool   InpAvoidRollover = true;   // Skip entries around the daily close/rollover
input int    InpRolloverHour  = 23;     // Server hour to avoid
input int    InpMaxPositions  = 1;      // Max concurrent positions (1 = one swing at a time)

input group "Engine"
input long   InpMagic         = 77032024; // Magic (distinct)
input int    InpSlippage      = 40;       // Max deviation, points (wider TF => allow a bit more)
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
int      hATR=INVALID_HANDLE, hEmaF=INVALID_HANDLE, hEmaS=INVALID_HANDLE;

datetime m_lastBar    = 0;
int      m_dayWins    = 0;
int      m_dayLosses  = 0;
double   m_dayStartBal= 0.0;
int      m_curDay     = -1;
bool     m_dayHalted  = false;
string   g_lastSkip   = "";

double   PtsToPips(double pts){ return pts / g_ppp; }
double   PipsToPts(double pips){ return pips * g_ppp; }
void     Log(const string s){ if(InpEnableLog) Print("[Swing] ", s); }
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

   if(InpRewardRatio<1.0){ Print("[Swing] RewardRatio should be >= 1 for positive expectancy."); }
   if(InpStopAtrMult<=0 || InpRiskMoney<=0)
     { Print("[Swing] stop mult and risk money must be > 0."); return INIT_PARAMETERS_INCORRECT; }

   hATR  = iATR(m_sym,_Period,InpAtrPeriod);
   hEmaF = iMA(m_sym,_Period,InpEmaFast,0,MODE_EMA,PRICE_CLOSE);
   hEmaS = iMA(m_sym,_Period,InpEmaSlow,0,MODE_EMA,PRICE_CLOSE);
   if(hATR==INVALID_HANDLE || hEmaF==INVALID_HANDLE || hEmaS==INVALID_HANDLE)
     { Print("[Swing] indicator handle failed."); return INIT_FAILED; }

   m_trade.SetExpertMagicNumber(InpMagic);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFillingBySymbol(m_sym);

   m_dayStartBal=AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); m_curDay=dt.day_of_year;

   if(InpShowPanel) PanelCreate();
   Log(StringFormat("init v1.0 TF=%s risk(£)=%.2f R=%.2f stop=%.1fxATR Donchian=%d EMA %d/%d",
        EnumToString(_Period),InpRiskMoney,InpRewardRatio,InpStopAtrMult,InpDonchianBars,InpEmaFast,InpEmaSlow));
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
//  INDICATOR HELPERS
//====================================================================
double ATRnow(){ double b[]; if(CopyBuffer(hATR,0,0,1,b)<1)return 0; return b[0]; }
double EmaFast(int sh=0){ double b[]; if(CopyBuffer(hEmaF,0,sh,1,b)<1)return 0; return b[0]; }
double EmaSlow(int sh=0){ double b[]; if(CopyBuffer(hEmaS,0,sh,1,b)<1)return 0; return b[0]; }
double DonHigh(int bars){ int i=iHighest(m_sym,_Period,MODE_HIGH,bars,1); return (i<0)?0:iHigh(m_sym,_Period,i); }
double DonLow (int bars){ int i=iLowest (m_sym,_Period,MODE_LOW ,bars,1); return (i<0)?0:iLow (m_sym,_Period,i); }

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
   double tickVal=SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_SIZE);
   if(tickVal<=0 || tickSize<=0 || stopPoints<=0) return InpMinLot;
   double lossPerLot=(stopPoints*m_point/tickSize)*tickVal;
   if(lossPerLot<=0) return InpMinLot;
   double lot=InpRiskMoney/lossPerLot;
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
       m_dayWins=0; m_dayLosses=0; m_dayHalted=false; Log("new day"); }
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
bool VolatilityOK(double atr)
  {
   if(InpAtrMinPips<=0) return true;
   return PtsToPips(atr/m_point) >= InpAtrMinPips;
  }

//====================================================================
//  ENTRY (Donchian breakout WITH the higher-TF trend)
//====================================================================
int Signal()
  {
   double hi=DonHigh(InpDonchianBars), lo=DonLow(InpDonchianBars);
   if(hi<=0 || lo<=0){ g_lastSkip="channel not ready"; return 0; }
   double buf=InpBufferPoints*m_point;

   double ef=EmaFast(), es=EmaSlow(), ef1=EmaFast(1);
   //--- trend: price above both EMAs and fast>slow for longs (mirror for shorts)
   bool trendUp = true, trendDn = true;
   if(InpUseEmaStack)
     { trendUp = (ef>es && Bid()>ef);
       trendDn = (ef<es && Ask()<ef); }
   if(InpUseEmaSlope)
     { trendUp = trendUp && (ef>ef1);
       trendDn = trendDn && (ef<ef1); }

   bool upBreak = (Ask() > hi+buf);
   bool dnBreak = (Bid() < lo-buf);

   if(upBreak && trendUp) return +1;
   if(dnBreak && trendDn) return -1;

   if(upBreak && !trendUp)      g_lastSkip="up-break but trend not up";
   else if(dnBreak && !trendDn) g_lastSkip="dn-break but trend not down";
   else                         g_lastSkip="no channel breakout";
   return 0;
  }

void TryEnter()
  {
   double atr=ATRnow();
   if(atr<=0){ g_lastSkip="ATR not ready"; return; }
   if(!VolatilityOK(atr)){ g_lastSkip="ATR gate"; return; }
   if(!SpreadOK()){ g_lastSkip="spread too wide"; return; }
   if(!RolloverOK()){ g_lastSkip="rollover/close"; return; }

   int sig=Signal();
   if(sig==0) return;

   double stopDist=atr*InpStopAtrMult, stopPts=stopDist/m_point;
   double lot=LotForRisk(stopPts);
   double sl,tp,entry;
   if(sig>0)
     { entry=Ask(); sl=Nz(entry-stopDist); tp=Nz(entry+stopDist*InpRewardRatio);
       if(!m_trade.Buy(lot,m_sym,0,sl,tp,"Swing")){ Log(StringFormat("BUY failed rc=%u",m_trade.ResultRetcode())); return; }
       Log(StringFormat("LONG %.2f @%.*f SL=%.*f TP=%.*f (ATR=%.0fpt)",lot,m_digits,entry,m_digits,sl,m_digits,tp,atr/m_point)); }
   else
     { entry=Bid(); sl=Nz(entry+stopDist); tp=Nz(entry-stopDist*InpRewardRatio);
       if(!m_trade.Sell(lot,m_sym,0,sl,tp,"Swing")){ Log(StringFormat("SELL failed rc=%u",m_trade.ResultRetcode())); return; }
       Log(StringFormat("SHORT %.2f @%.*f SL=%.*f TP=%.*f (ATR=%.0fpt)",lot,m_digits,entry,m_digits,sl,m_digits,tp,atr/m_point)); }
  }

//====================================================================
//  MANAGE: break-even + ATR trail (never widen)
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
   if(!newBar) return;              // swing EA: evaluate once per (H1/H4) bar
   m_lastBar=bt;

   if(DailyHalted()){ if(InpDebugSkips)Log("skip: daily halt"); return; }
   if(MyPositions()>=InpMaxPositions){ if(InpDebugSkips)Log("skip: max positions"); return; }

   g_lastSkip="";
   TryEnter();
   if(InpDebugSkips && g_lastSkip!="") Log("skip: "+g_lastSkip);
  }

//====================================================================
//  STATUS PANEL
//====================================================================
#define SW "SW_"
color PS_BG=C'18,24,20', PS_GOLD=C'214,175,55', PS_TXT=C'230,232,238',
      PS_GRN=C'0,170,80', PS_RED=C'210,60,66', PS_MUTE=C'150,160,175';
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
   ObjectSetInteger(0,n,OBJPROP_COLOR,PS_GOLD); ObjectSetInteger(0,n,OBJPROP_BACK,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }
void PanelCreate()
  {
   int x=10,y=22,w=330,h=132;
   pRect(SW"bg",x,y,w,h,PS_BG);
   pLbl(SW"ttl",x+10,y+8,StringFormat("SwingTrader (%s)",EnumToString(_Period)),PS_GOLD,11,true);
  }
void PanelDestroy(){ ObjectsDeleteAll(0,SW); }
void PanelUpdate()
  {
   if(!InpShowPanel) return;
   double atr=ATRnow(); double ef=EmaFast(), es=EmaSlow();
   string trend = (ef>es)?"UP":"DOWN";
   double dpl=DayPL();
   string pos="Position: flat";
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       bool lng=((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
       double entry=PositionGetDouble(POSITION_PRICE_OPEN), sl=PositionGetDouble(POSITION_SL);
       double cur=lng?Bid():Ask(); double rd=MathAbs(entry-sl); double pd=lng?(cur-entry):(entry-cur);
       double r=(rd>0)?pd/rd:0;
       pos=StringFormat("Position: %s %.2f  R=%.2f  P/L=%.2f",lng?"LONG":"SHORT",PositionGetDouble(POSITION_VOLUME),r,PositionGetDouble(POSITION_PROFIT));
       break; }
   pLbl(SW"l1",24,56,StringFormat("Trend: %s   ATR: %.0f pt",trend,atr/m_point),PS_TXT,9);
   pLbl(SW"l2",24,76,pos,PS_TXT,9);
   pLbl(SW"l3",24,96,StringFormat("Day P/L: %.2f  (limit -%.0f)",dpl,InpDailyLossStop),dpl>=0?PS_GRN:PS_RED,9);
   pLbl(SW"l4",24,116,StringFormat("Wins: %d  Losses: %d",m_dayWins,m_dayLosses),PS_MUTE,9);
   pLbl(SW"l5",24,134,StringFormat("risk £%.2f  R:R 1:%.1f  stop %.1fxATR",InpRiskMoney,InpRewardRatio,InpStopAtrMult),PS_MUTE,8);
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
