//+------------------------------------------------------------------+
//| Expert Advisor: Pro Scalper Terminal v22                         |
//| Manual BUY/SELL scalper with dynamic gaps and mild recovery mode. |
//| Auto/Athena trade engine removed.                                |
//+------------------------------------------------------------------+
#property strict

input int    InpGap2PullbackWaitSeconds = 30;
input int    InpGap2PullbackPoints      = 30;
input int    InpGap2StartMatchPoints    = 100;
input int    InpScalpPullbackWaitSeconds = 30;
input int    InpScalpPullbackPoints      = 30;
input double InpAbsoluteGapPriceLevel    = 1000.0;
input double InpProSTargetOffset         = 30.0;

//==========================================================================
//  STAIRCASE TP/SL (split order: P1/P2/P3)
//==========================================================================
input bool   InpStaircaseEnabled   = true;   // Enable staircase T/P for the P1/P2/P3 split order
input double InpStairP1TPPct       = 3.0;    // P1 T/P, % of trade value
input double InpStairStage1SLPct   = 2.5;    // P2 & P3 S/L after P1 closes, % of trade value
input double InpStairStage1TPPct   = 6.0;    // P2 & P3 T/P after P1 closes, % of trade value
input double InpStairStage2SLPct   = 5.0;    // P3 S/L after P2 closes, % of trade value
input double InpStairStage2TPPct   = 9.0;    // P3 T/P after P2 closes, % of trade value

//==========================================================================
//  AUTO SUPPORT/RESISTANCE (Target price, per side, on this chart's timeframe)
//==========================================================================
input int    InpSRLookbackBars = 200;  // Bars scanned for swing highs/lows on this chart's timeframe
input int    InpSRFractalWidth = 2;    // Bars required on each side to confirm a swing point (2 = classic 5-bar fractal)

//==========================================================================
//  BACKTEST-ONLY AUTO START (never fires outside the Strategy Tester)
//==========================================================================
input bool   InpAutoStartForBacktest = false; // Testing only: at OnInit, auto-clicks Start on both sides and turns Auto S/R on, so a headless/optimizer backtest can run unattended. Gated to MQL_TESTER regardless of this flag.

//==========================================================================
//  ACCOUNT AUTHORIZATION
//==========================================================================
struct AccountAuth { long accNum; string name; datetime expiry; };
AccountAuth authAccounts[] =
{
   {410289709,"HOME RENT",D'2029.12.30'},{410093820,"CAR LOAN",D'2029.12.30'},
   {410042513,"JINTO",D'2029.12.30'},{410393786,"INTRADAY",D'2029.12.30'},
   {410398444,"LUKOSE",D'2029.12.30'},{81609479,"Jins Demo",D'2029.12.30'},
   {104596471,"DEMO",D'2029.12.30'},{410069724,"CA LUK",D'2029.12.30'},
   {5929017,"JOMON TEST",D'2029.12.30'},{476224288,"Jins test",D'2029.12.30'},
   {5055445576,"BACKTEST",D'2029.12.30'},{112886848,"BACKTEST2",D'2029.12.30'}
};
string g_AccountName="";

//==========================================================================
//  CONSTANTS / GLOBALS
//==========================================================================
long BASE_BUY_MAGIC   = 98764895252;
long BASE_SELL_MAGIC  = 98765895252;
long BUY_OPP_MAGIC    = 98768895252;
long SELL_OPP_MAGIC   = 98769895252;
long currBuyM, currSellM;

int  DEFAULT_GAPS = 4;
int  MAX_GAPS     = 4;
int  MAX_REOPEN_DELAY = 0;
int  BAD_CLOSE_LIMIT  = 3;
double DEFAULT_GAP_VALUE  = 5.00;
double DEFAULT_GAP_LOT    = 0.01;
double DEFAULT_GAP_PROFIT = 1.00;
double DEFAULT_GAP_LOCK   = 0.50;
int    PROS_INDEX         = 3;
string RESTART_BTN_TEXT   = "⭮";
string BTN_START_TEXT     = "▶";
string BTN_PAUSE_TEXT     = "Ⅱ";
string BTN_STOP_TEXT      = "■";
string BTN_SYNC_TEXT      = "↻";
long   OSP_MAGIC           = 26090801;

double minLot=0,maxLot=0,lotStep=0;
string GV_PREFIX="";
string gLastErrorText="";

//==========================================================================
//  SESSION STATE
//==========================================================================
bool bOn=false,bPaused=false,bRepeat=false,bStartReached=false,bStartAbove=false;
bool sOn=false,sPaused=false,sRepeat=false,sStartReached=false,sStartAbove=false;
bool uiCollapsed=false;
bool ospExpanded=false,ospRunning=false,ospPaused=false;
bool ospMAEnabled=true,ospRiskEnabled=false,ospSMCEnabled=false;
bool ospNewsGuard=true,ospVolatilityGuard=true;
int  ospMode=2; // 0=BUY, 1=SELL, 2=BOTH
int  ospFastEMA=50,ospSlowEMA=200,ospMaxBuy=-1,ospMaxSell=-1;
int  ospFastHandle=INVALID_HANDLE,ospSlowHandle=INVALID_HANDLE,ospATRHandle=INVALID_HANDLE;
datetime ospLastBar=0;
double ospTarget=1.00,ospQty=0.01,ospWidth=1.00,ospSL=1.00;
string ospStatus="Ready";

double bStart=0,bTarget=0,bLot1=0.01;
double sStart=0,sTarget=0,sLot1=0.01;
double bProtectMoney=2.00,sProtectMoney=2.00;
double bLockMoney=1.00,sLockMoney=1.00;
double bBasketMoney=100.00,sBasketMoney=100.00;
bool   bBasketOn=false,sBasketOn=false;
double bStopPrice=0,sStopPrice=0;
bool   bStopOn=false,sStopOn=false;
bool bBasketClosed=false,sBasketClosed=false;
bool bOppOn=false,sOppOn=false;
double bOppMoney=1.00,sOppMoney=1.00;
bool bAutoSR=false,sAutoSR=false;
datetime gLastSRBarTime=0;

ulong  bTicket1=0,sTicket1=0;
double bEntry1=0,sEntry1=0,bStuck1=0,sStuck1=0;
datetime bLastClose1=0,sLastClose1=0;
int bScalp1=0,sScalp1=0,bBadCloses=0,sBadCloses=0;

// Staircase T/P state for the P1/P2/P3 split order. 0=P1 still open, 1=P1 closed, 2=P1+P2 closed.
int bStairStage=0,sStairStage=0;

int bGapCount=0,sGapCount=0;
double bGap[],bLot[],bTP[],bLock[],bEntry[],bStuck[],bReturnTarget[],bArmedPrice[];
double sGap[],sLot[],sTP[],sLock[],sEntry[],sStuck[],sReturnTarget[],sArmedPrice[];
bool   bGapOn[],bActive[],sGapOn[],sActive[];
ulong  bTicket[],sTicket[];
datetime bLastClose[],sLastClose[];
int    bScalps[],sScalps[];

datetime bSyncFlash=0,sSyncFlash=0,bCloseFlash=0,sCloseFlash=0;
bool bScalpPullbackActive=false,sScalpPullbackActive=false;
datetime bScalpPullbackStart=0,sScalpPullbackStart=0;
double bScalpPullbackRef=0,sScalpPullbackRef=0;
datetime bGap2PullbackStart=0,sGap2PullbackStart=0;

//==========================================================================
//  BASIC HELPERS
//==========================================================================
bool CheckAuthorization()
{
   long acc=AccountInfoInteger(ACCOUNT_LOGIN);
   datetime now=TimeCurrent();
   for(int i=0;i<ArraySize(authAccounts);i++)
   {
      if(authAccounts[i].accNum==acc)
      {
         if(now>authAccounts[i].expiry){ Alert("License expired."); return false; }
         g_AccountName=authAccounts[i].name;
         return true;
      }
   }
   Alert("Account not authorized.");
   return false;
}

double NormalizeLot(double lots)
{
   if(lots<minLot) return 0;
   if(lots>maxLot) lots=maxLot;
   double steps=MathFloor((lots+0.0000001)/lotStep);
   return NormalizeDouble(steps*lotStep,2);
}

bool CanTrade()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(SymbolInfoDouble(_Symbol,SYMBOL_ASK)<=0) return false;
   if(SymbolInfoDouble(_Symbol,SYMBOL_BID)<=0) return false;
   return true;
}

double MoneyGapToPrice(double money,double lots)
{
   lots=NormalizeLot(lots);
   if(money<=0||lots<=0) return 0;
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(ts<=0||tv<=0) return 0;
   return (money/(tv*lots))*ts;
}

double PriceGap(double gap)
{
   if(gap<=0) return 0;
   return NormalizeDouble(gap,_Digits);
}

string Dbl(double v,int d=2){ return DoubleToString(v,d); }

bool IsProSIndex(int index)
{
   return (index==PROS_INDEX);
}

string OSPName(string suffix){ return "UI_OSP_"+suffix; }

int VolumeDigitsForStep(double step)
{
   int digits=0;
   while(step<1.0&&digits<8){ step*=10.0;digits++; }
   return digits;
}

double OSPValidVolume(double requested)
{
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) return 0;
   double volume=MathFloor(MathMin(requested,maxLot)/step)*step;
   if(volume<minLot) return 0;
   return NormalizeDouble(volume,VolumeDigitsForStep(step));
}

bool OSPTargetDistance(double volume,double &distance)
{
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_PROFIT);
   if(tickValue<=0) tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tickSize<=0||tickValue<=0||volume<=0) return false;
   distance=(ospTarget/(volume*tickValue))*tickSize;
   return distance>0;
}

int OSPCountActiveSide(bool isBuy)
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);if(ticket==0||!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)!=OSP_MAGIC) continue;
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((isBuy&&type==POSITION_TYPE_BUY)||(!isBuy&&type==POSITION_TYPE_SELL)) count++;
   }
   return count;
}

void OSPDeletePending()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);if(ticket==0||!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)==_Symbol&&OrderGetInteger(ORDER_MAGIC)==OSP_MAGIC) DeleteOrder(ticket);
   }
}

void OSPCloseAll()
{
   ospPaused=true;
   OSPDeletePending();
   int sent=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);if(ticket==0||!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol&&PositionGetInteger(POSITION_MAGIC)==OSP_MAGIC)
         if(ClosePosition(ticket)) sent++;
   }
   ospStatus="Close all sent: "+(string)sent+". Engine paused.";
}

bool OSPHasCapacity(bool isBuy)
{
   int maximum=isBuy?ospMaxBuy:ospMaxSell;
   int enabled=(ospMAEnabled?1:0)+(ospRiskEnabled?1:0)+(ospSMCEnabled?1:0);
   if(maximum>=0) maximum*=MathMax(1,enabled);
   return maximum<0||OSPCountActiveSide(isBuy)<maximum;
}

bool OSPPlaceLimit(bool isBuy,double volume,double entry,double sl,double tp,string comment,string &failure)
{
   MqlTradeRequest req;MqlTradeResult res;ZeroMemory(req);ZeroMemory(res);
   req.action=TRADE_ACTION_PENDING;req.magic=(ulong)OSP_MAGIC;req.symbol=_Symbol;req.volume=volume;
   req.price=entry;req.sl=ospSL==0?0:sl;req.tp=tp;
   req.type=isBuy?ORDER_TYPE_BUY_LIMIT:ORDER_TYPE_SELL_LIMIT;
   req.type_filling=ORDER_FILLING_RETURN;req.type_time=ORDER_TIME_GTC;req.comment=comment;
   if(!OrderSend(req,res)){ failure="order send failed";return false; }
   if(res.retcode!=TRADE_RETCODE_PLACED&&res.retcode!=TRADE_RETCODE_DONE)
   { failure="broker code "+(string)res.retcode;return false; }
   return true;
}

bool OSPTryPlace(bool isBuy,const MqlRates &candle,double volume,double tpDistance,string strategy,string &message)
{
   if(!OSPHasCapacity(isBuy)){message=strategy+" "+(isBuy?"buy":"sell")+" side at maximum.";return false;}
   MqlTick tick;if(!SymbolInfoTick(_Symbol,tick)){message="waiting for price";return false;}
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minimum=(stops+1)*_Point;
   double entry=NormalizeDouble(isBuy?candle.low+ospWidth/2.0:candle.high-ospWidth/2.0,_Digits);
   double sl=NormalizeDouble(isBuy?entry-ospSL:entry+ospSL,_Digits);
   double tp=NormalizeDouble(isBuy?entry+tpDistance:entry-tpDistance,_Digits);
   bool validSide=isBuy?entry<=tick.ask-minimum:entry>=tick.bid+minimum;
   bool validProtection=isBuy?(ospSL==0||entry-sl>=minimum)&&tp-entry>=minimum:(ospSL==0||sl-entry>=minimum)&&entry-tp>=minimum;
   if(!validSide){message=strategy+" level is on wrong side of market.";return false;}
   if(!validProtection){message=strategy+" SL or target is too close for broker.";return false;}
   if(!OSPPlaceLimit(isBuy,volume,entry,sl,tp,strategy+" "+(isBuy?"BUY":"SELL"),message)) return false;
   message=strategy+" "+(isBuy?"BUY":"SELL")+" limit placed.";return true;
}

string OSPVolatility()
{
   double values[];ArraySetAsSeries(values,true);
   if(ospATRHandle==INVALID_HANDLE||CopyBuffer(ospATRHandle,0,1,21,values)!=21) return "Loading";
   double average=0;for(int i=1;i<21;i++) average+=values[i];average/=20.0;
   if(values[0]>=average*1.60) return "Highest";
   if(values[0]>=average*1.15) return "High";
   if(values[0]<average*0.75) return "Low";
   return "Medium";
}

bool OSPHighImpactNews(string &details)
{
   datetime now=TimeTradeServer();if(now==0) now=TimeCurrent();
   MqlCalendarValue values[];int count=CalendarValueHistory(values,now-30*60,now+30*60);
   if(count<0) return false;
   string base=SymbolInfoString(_Symbol,SYMBOL_CURRENCY_BASE),profit=SymbolInfoString(_Symbol,SYMBOL_CURRENCY_PROFIT);
   for(int i=0;i<count;i++)
   {
      MqlCalendarEvent event;MqlCalendarCountry country;
      if(!CalendarEventById(values[i].event_id,event)||event.importance!=CALENDAR_IMPORTANCE_HIGH) continue;
      if(!CalendarCountryById(event.country_id,country)) continue;
      if(country.currency==base||country.currency==profit){details=country.currency+" news: "+event.name;return true;}
   }
   return false;
}

void OSPRefreshClosedCandle()
{
   if(ospPaused){ospStatus="Paused.";return;}
   string volatility=OSPVolatility();
   if(ospVolatilityGuard&&(volatility=="High"||volatility=="Highest")){ospStatus="Volatility guard: "+volatility+".";return;}
   string news="";if(ospNewsGuard&&OSPHighImpactNews(news)){ospStatus="News guard: "+news;return;}
   if(!ospMAEnabled&&!ospRiskEnabled&&!ospSMCEnabled){ospStatus="Enable MA, Risk, or SMC.";return;}
   MqlRates candles[];ArraySetAsSeries(candles,true);
   if(CopyRates(_Symbol,_Period,1,2,candles)!=2){ospStatus="Waiting for candle data.";return;}
   double volume=OSPValidVolume(ospQty),tpDistance=0;
   if(volume<=0){ospStatus="Lot is below broker minimum.";return;}
   if(!OSPTargetDistance(volume,tpDistance)){ospStatus="Cannot calculate money target.";return;}
   bool buySide=ospMode==0||ospMode==2,sellSide=ospMode==1||ospMode==2;
   bool maBuy=false,maSell=false;
   if(ospMAEnabled)
   {
      double fast[],slow[];
      if(CopyBuffer(ospFastHandle,0,1,1,fast)!=1||CopyBuffer(ospSlowHandle,0,1,1,slow)!=1){ospStatus="Waiting for EMA data.";return;}
      maBuy=buySide&&fast[0]<slow[0];maSell=sellSide&&fast[0]>slow[0];
   }
   bool riskBuy=ospRiskEnabled&&buySide,riskSell=ospRiskEnabled&&sellSide;
   bool smcBuy=ospSMCEnabled&&buySide&&candles[0].low<candles[1].low&&candles[0].close>candles[0].open;
   bool smcSell=ospSMCEnabled&&sellSide&&candles[0].high>candles[1].high&&candles[0].close<candles[0].open;
   int placed=0;string last="No enabled strategy signalled.";string message="";
   if(maBuy&&OSPTryPlace(true,candles[0],volume,tpDistance,"MA",message)){placed++;last=message;}
   else if(maBuy) last=message;
   if(maSell&&OSPTryPlace(false,candles[0],volume,tpDistance,"MA",message)){placed++;last=message;}
   else if(maSell) last=message;
   if(riskBuy&&OSPTryPlace(true,candles[0],volume,tpDistance,"Risk",message)){placed++;last=message;}
   else if(riskBuy) last=message;
   if(riskSell&&OSPTryPlace(false,candles[0],volume,tpDistance,"Risk",message)){placed++;last=message;}
   else if(riskSell) last=message;
   if(smcBuy&&OSPTryPlace(true,candles[0],volume,tpDistance,"SMC",message)){placed++;last=message;}
   else if(smcBuy) last=message;
   if(smcSell&&OSPTryPlace(false,candles[0],volume,tpDistance,"SMC",message)){placed++;last=message;}
   else if(smcSell) last=message;
   ospStatus=placed>0?(string)placed+" pending order(s) placed.":last;
}

void OSPManage()
{
   if(!ospRunning) return;
   datetime bar=iTime(_Symbol,_Period,0);
   if(ospPaused){if(bar!=0) ospLastBar=bar;return;}
   if(bar!=0&&bar!=ospLastBar){ospLastBar=bar;OSPDeletePending();OSPRefreshClosedCandle();}
}

double DefaultProSTarget(bool isBuy)
{
   double price=SymbolInfoDouble(_Symbol,isBuy?SYMBOL_ASK:SYMBOL_BID);
   double offset=MathMax(0.0,InpProSTargetOffset);
   if(price<=0) return offset;
   double target=isBuy?price+offset:price-offset;
   if(!isBuy&&target<=0) target=price-(offset*_Point);
   if(target<=0) target=price;
   return NormalizeDouble(target,_Digits);
}

void SetError(string t)
{
   gLastErrorText=t;
   Alert(t);
   Print(t);
}

//==========================================================================
//  DYNAMIC GAP ARRAYS
//==========================================================================
void ResizeBuyGaps(int newCount)
{
   if(newCount<0) newCount=0;
   if(newCount>MAX_GAPS) newCount=MAX_GAPS;
   int old=ArraySize(bGap);
   ArrayResize(bGap,newCount);ArrayResize(bLot,newCount);ArrayResize(bTP,newCount);ArrayResize(bLock,newCount);
   ArrayResize(bGapOn,newCount);ArrayResize(bTicket,newCount);ArrayResize(bEntry,newCount);
   ArrayResize(bStuck,newCount);ArrayResize(bReturnTarget,newCount);ArrayResize(bActive,newCount);
   ArrayResize(bLastClose,newCount);ArrayResize(bScalps,newCount);ArrayResize(bArmedPrice,newCount);
   for(int i=old;i<newCount;i++)
   {
      bGap[i]=IsProSIndex(i)?0.0:DEFAULT_GAP_VALUE;
      bLot[i]=DEFAULT_GAP_LOT;
      bTP[i]=IsProSIndex(i)?DefaultProSTarget(true):DEFAULT_GAP_PROFIT;
      bLock[i]=DEFAULT_GAP_LOCK;
      bGapOn[i]=true;
      bTicket[i]=0;bEntry[i]=0;bStuck[i]=0;bReturnTarget[i]=0;bActive[i]=false;
      bLastClose[i]=0;bScalps[i]=0;bArmedPrice[i]=0;
   }
   bGapCount=newCount;
}

void ResizeSellGaps(int newCount)
{
   if(newCount<0) newCount=0;
   if(newCount>MAX_GAPS) newCount=MAX_GAPS;
   int old=ArraySize(sGap);
   ArrayResize(sGap,newCount);ArrayResize(sLot,newCount);ArrayResize(sTP,newCount);ArrayResize(sLock,newCount);
   ArrayResize(sGapOn,newCount);ArrayResize(sTicket,newCount);ArrayResize(sEntry,newCount);
   ArrayResize(sStuck,newCount);ArrayResize(sReturnTarget,newCount);ArrayResize(sActive,newCount);
   ArrayResize(sLastClose,newCount);ArrayResize(sScalps,newCount);ArrayResize(sArmedPrice,newCount);
   for(int i=old;i<newCount;i++)
   {
      sGap[i]=IsProSIndex(i)?0.0:DEFAULT_GAP_VALUE;
      sLot[i]=DEFAULT_GAP_LOT;
      sTP[i]=IsProSIndex(i)?DefaultProSTarget(false):DEFAULT_GAP_PROFIT;
      sLock[i]=DEFAULT_GAP_LOCK;
      sGapOn[i]=true;
      sTicket[i]=0;sEntry[i]=0;sStuck[i]=0;sReturnTarget[i]=0;sActive[i]=false;
      sLastClose[i]=0;sScalps[i]=0;sArmedPrice[i]=0;
   }
   sGapCount=newCount;
}

void ResetBuyRunState()
{
   bTicket1=0;bEntry1=0;bStuck1=0;bLastClose1=0;bScalp1=0;bBadCloses=0;bStartReached=false;
   bScalpPullbackActive=false;bScalpPullbackStart=0;bScalpPullbackRef=0;bGap2PullbackStart=0;
   bStairStage=0;
   for(int i=0;i<bGapCount;i++)
   {
      bTicket[i]=0;bEntry[i]=0;bStuck[i]=0;bReturnTarget[i]=0;bActive[i]=false;
      bLastClose[i]=0;bScalps[i]=0;bArmedPrice[i]=0;
   }
}

void ResetSellRunState()
{
   sTicket1=0;sEntry1=0;sStuck1=0;sLastClose1=0;sScalp1=0;sBadCloses=0;sStartReached=false;
   sScalpPullbackActive=false;sScalpPullbackStart=0;sScalpPullbackRef=0;sGap2PullbackStart=0;
   sStairStage=0;
   for(int i=0;i<sGapCount;i++)
   {
      sTicket[i]=0;sEntry[i]=0;sStuck[i]=0;sReturnTarget[i]=0;sActive[i]=false;
      sLastClose[i]=0;sScalps[i]=0;sArmedPrice[i]=0;
   }
}

//==========================================================================
//  TRADE HELPERS
//==========================================================================
ulong ExecuteBuy(double lots,string cmt)
{
   lots=NormalizeLot(lots);
   if(lots<=0||!CanTrade()) return 0;
   MqlTradeRequest req;MqlTradeResult res;
   ZeroMemory(req);ZeroMemory(res);
   req.action=TRADE_ACTION_DEAL;
   req.symbol=_Symbol;
   req.volume=lots;
   req.type=ORDER_TYPE_BUY;
   req.price=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   req.deviation=30;
   req.magic=(ulong)currBuyM;
   req.comment=cmt;
   req.type_filling=ORDER_FILLING_IOC;
   if(!OrderSend(req,res)) return 0;
   if(res.retcode!=TRADE_RETCODE_DONE&&res.retcode!=TRADE_RETCODE_PLACED) return 0;
   ulong deal=res.deal;
   if(deal>0&&HistoryDealSelect(deal))
      return (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
   return 0;
}

ulong ExecuteBuyMagic(double lots,string cmt,long magic)
{
   lots=NormalizeLot(lots);
   if(lots<=0||!CanTrade()) return 0;
   MqlTradeRequest req;MqlTradeResult res;
   ZeroMemory(req);ZeroMemory(res);
   req.action=TRADE_ACTION_DEAL;
   req.symbol=_Symbol;
   req.volume=lots;
   req.type=ORDER_TYPE_BUY;
   req.price=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   req.deviation=30;
   req.magic=(ulong)magic;
   req.comment=cmt;
   req.type_filling=ORDER_FILLING_IOC;
   if(!OrderSend(req,res)) return 0;
   if(res.retcode!=TRADE_RETCODE_DONE&&res.retcode!=TRADE_RETCODE_PLACED) return 0;
   ulong deal=res.deal;
   if(deal>0&&HistoryDealSelect(deal))
      return (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
   return 0;
}

ulong ExecuteBuyMagicTP(double lots,string cmt,long magic,double tpMoney)
{
   lots=NormalizeLot(lots);
   if(lots<=0||!CanTrade()) return 0;
   double price=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double dist=MoneyAmountToPriceDistance(tpMoney,lots);
   if(dist<=0) return 0;
   MqlTradeRequest req;MqlTradeResult res;
   ZeroMemory(req);ZeroMemory(res);
   req.action=TRADE_ACTION_DEAL;
   req.symbol=_Symbol;
   req.volume=lots;
   req.type=ORDER_TYPE_BUY;
   req.price=price;
   req.tp=NormalizeDouble(price+dist,_Digits);
   req.deviation=30;
   req.magic=(ulong)magic;
   req.comment=cmt;
   req.type_filling=ORDER_FILLING_IOC;
   if(!OrderSend(req,res)) return 0;
   if(res.retcode!=TRADE_RETCODE_DONE&&res.retcode!=TRADE_RETCODE_PLACED) return 0;
   ulong deal=res.deal;
   if(deal>0&&HistoryDealSelect(deal))
      return (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
   return 0;
}

ulong ExecuteSell(double lots,string cmt)
{
   lots=NormalizeLot(lots);
   if(lots<=0||!CanTrade()) return 0;
   MqlTradeRequest req;MqlTradeResult res;
   ZeroMemory(req);ZeroMemory(res);
   req.action=TRADE_ACTION_DEAL;
   req.symbol=_Symbol;
   req.volume=lots;
   req.type=ORDER_TYPE_SELL;
   req.price=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   req.deviation=30;
   req.magic=(ulong)currSellM;
   req.comment=cmt;
   req.type_filling=ORDER_FILLING_IOC;
   if(!OrderSend(req,res)) return 0;
   if(res.retcode!=TRADE_RETCODE_DONE&&res.retcode!=TRADE_RETCODE_PLACED) return 0;
   ulong deal=res.deal;
   if(deal>0&&HistoryDealSelect(deal))
      return (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
   return 0;
}

ulong ExecuteSellMagic(double lots,string cmt,long magic)
{
   lots=NormalizeLot(lots);
   if(lots<=0||!CanTrade()) return 0;
   MqlTradeRequest req;MqlTradeResult res;
   ZeroMemory(req);ZeroMemory(res);
   req.action=TRADE_ACTION_DEAL;
   req.symbol=_Symbol;
   req.volume=lots;
   req.type=ORDER_TYPE_SELL;
   req.price=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   req.deviation=30;
   req.magic=(ulong)magic;
   req.comment=cmt;
   req.type_filling=ORDER_FILLING_IOC;
   if(!OrderSend(req,res)) return 0;
   if(res.retcode!=TRADE_RETCODE_DONE&&res.retcode!=TRADE_RETCODE_PLACED) return 0;
   ulong deal=res.deal;
   if(deal>0&&HistoryDealSelect(deal))
      return (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
   return 0;
}

ulong ExecuteSellMagicTP(double lots,string cmt,long magic,double tpMoney)
{
   lots=NormalizeLot(lots);
   if(lots<=0||!CanTrade()) return 0;
   double price=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double dist=MoneyAmountToPriceDistance(tpMoney,lots);
   if(dist<=0) return 0;
   MqlTradeRequest req;MqlTradeResult res;
   ZeroMemory(req);ZeroMemory(res);
   req.action=TRADE_ACTION_DEAL;
   req.symbol=_Symbol;
   req.volume=lots;
   req.type=ORDER_TYPE_SELL;
   req.price=price;
   req.tp=NormalizeDouble(price-dist,_Digits);
   req.deviation=30;
   req.magic=(ulong)magic;
   req.comment=cmt;
   req.type_filling=ORDER_FILLING_IOC;
   if(!OrderSend(req,res)) return 0;
   if(res.retcode!=TRADE_RETCODE_DONE&&res.retcode!=TRADE_RETCODE_PLACED) return 0;
   ulong deal=res.deal;
   if(deal>0&&HistoryDealSelect(deal))
      return (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
   return 0;
}

ulong PlaceSellLimitTP(double lots,double entryPrice,double tpPrice,string cmt,long magic)
{
   lots=NormalizeLot(lots);
   if(lots<=0||!CanTrade()) return 0;
   MqlTradeRequest req;MqlTradeResult res;
   ZeroMemory(req);ZeroMemory(res);
   req.action=TRADE_ACTION_PENDING;
   req.symbol=_Symbol;
   req.volume=lots;
   req.type=ORDER_TYPE_SELL_LIMIT;
   req.price=NormalizeDouble(entryPrice,_Digits);
   req.tp=NormalizeDouble(tpPrice,_Digits);
   req.deviation=30;
   req.magic=(ulong)magic;
   req.comment=cmt;
   req.type_filling=ORDER_FILLING_IOC;
   req.type_time=ORDER_TIME_GTC;
   if(!OrderSend(req,res)) return 0;
   if(res.retcode!=TRADE_RETCODE_DONE&&res.retcode!=TRADE_RETCODE_PLACED) return 0;
   return res.order;
}

ulong PlaceBuyLimitTP(double lots,double entryPrice,double tpPrice,string cmt,long magic)
{
   lots=NormalizeLot(lots);
   if(lots<=0||!CanTrade()) return 0;
   MqlTradeRequest req;MqlTradeResult res;
   ZeroMemory(req);ZeroMemory(res);
   req.action=TRADE_ACTION_PENDING;
   req.symbol=_Symbol;
   req.volume=lots;
   req.type=ORDER_TYPE_BUY_LIMIT;
   req.price=NormalizeDouble(entryPrice,_Digits);
   req.tp=NormalizeDouble(tpPrice,_Digits);
   req.deviation=30;
   req.magic=(ulong)magic;
   req.comment=cmt;
   req.type_filling=ORDER_FILLING_IOC;
   req.type_time=ORDER_TIME_GTC;
   if(!OrderSend(req,res)) return 0;
   if(res.retcode!=TRADE_RETCODE_DONE&&res.retcode!=TRADE_RETCODE_PLACED) return 0;
   return res.order;
}

bool ClosePosition(ulong ticket)
{
   if(ticket==0||!PositionSelectByTicket(ticket)) return false;
   ENUM_POSITION_TYPE posType=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double volume=PositionGetDouble(POSITION_VOLUME);
   MqlTradeRequest req;MqlTradeResult res;
   ZeroMemory(req);ZeroMemory(res);
   req.action=TRADE_ACTION_DEAL;
   req.position=ticket;
   req.symbol=PositionGetString(POSITION_SYMBOL);
   req.volume=volume;
   req.type=(posType==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
   req.price=(posType==POSITION_TYPE_BUY)?SymbolInfoDouble(req.symbol,SYMBOL_BID):SymbolInfoDouble(req.symbol,SYMBOL_ASK);
   req.deviation=30;
   req.magic=(ulong)PositionGetInteger(POSITION_MAGIC);
   req.comment="CLOSE";
   req.type_filling=ORDER_FILLING_IOC;
   if(!OrderSend(req,res)) return false;
   return (res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_PLACED);
}

bool DeleteOrder(ulong ticket)
{
   if(ticket==0||!OrderSelect(ticket)) return false;
   MqlTradeRequest req;MqlTradeResult res;
   ZeroMemory(req);ZeroMemory(res);
   req.action=TRADE_ACTION_REMOVE;
   req.order=ticket;
   req.symbol=OrderGetString(ORDER_SYMBOL);
   if(!OrderSend(req,res)) return false;
   return (res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_PLACED);
}

void DeleteEAOrders(int dir=0)
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0||!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      long magic=OrderGetInteger(ORDER_MAGIC);
      if(!IsThisEAMagic(magic)) continue;
      if(dir==1&&!IsBuyEngineMagic(magic)) continue;
      if(dir==-1&&!IsSellEngineMagic(magic)) continue;
      DeleteOrder(ticket);
   }
}

double PositionProfit(ulong ticket)
{
   if(ticket==0||!PositionSelectByTicket(ticket)) return 0;
   return PositionGetDouble(POSITION_PROFIT);
}

bool IsThisEAMagic(long magic)
{
   return (magic==currBuyM||magic==currSellM||magic==BUY_OPP_MAGIC||magic==SELL_OPP_MAGIC);
}

bool IsBuyEngineMagic(long magic)
{
   return (magic==currBuyM||magic==BUY_OPP_MAGIC);
}

bool IsSellEngineMagic(long magic)
{
   return (magic==currSellM||magic==SELL_OPP_MAGIC);
}

double MoneyAmountToPriceDistance(double money,double volume)
{
   double amount=MathAbs(money);
   volume=NormalizeLot(volume);
   if(amount<=0||volume<=0) return 0;
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(ts<=0||tv<=0) return 0;
   return (amount/(tv*volume))*ts;
}

double LockSLPrice(bool isBuy,double openPrice,double volume,double lockMoney)
{
   double dist=MoneyAmountToPriceDistance(lockMoney,volume);
   if(dist<=0) return 0;
   if(isBuy) return NormalizeDouble(openPrice+(lockMoney>=0?dist:-dist),_Digits);
   return NormalizeDouble(openPrice-(lockMoney>=0?dist:-dist),_Digits);
}

bool StopDistanceOK(bool isBuy,double slPrice)
{
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   if(stops<=0) return true;
   double minDist=stops*_Point;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   if(isBuy) return (bid-slPrice)>=minDist;
   return (slPrice-ask)>=minDist;
}

bool ModifyPositionSL(ulong ticket,double slPrice)
{
   if(ticket==0||!PositionSelectByTicket(ticket)||slPrice<=0) return false;
   ENUM_POSITION_TYPE posType=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   bool isBuy=(posType==POSITION_TYPE_BUY);
   slPrice=NormalizeDouble(slPrice,_Digits);
   if(!StopDistanceOK(isBuy,slPrice)) return false;
   MqlTradeRequest req;MqlTradeResult res;
   ZeroMemory(req);ZeroMemory(res);
   req.action=TRADE_ACTION_SLTP;
   req.position=ticket;
   req.symbol=PositionGetString(POSITION_SYMBOL);
   req.sl=slPrice;
   req.tp=PositionGetDouble(POSITION_TP);
   req.magic=(ulong)PositionGetInteger(POSITION_MAGIC);
   if(!OrderSend(req,res)) return false;
   return (res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_PLACED);
}

//==========================================================================
//  STAIRCASE TP/SL HELPERS (split order: P1/P2/P3)
//==========================================================================
// Trade value = volume*contract_size*price, and profit for a price move of D is
// volume*contract_size*D, so "X% of trade value" as a profit/loss target always
// reduces to a price move of exactly X% of the entry price, regardless of lot size.
double StaircasePrice(bool isBuy,double entryPrice,double pct,bool profitSide)
{
   double factor=pct/100.0;
   bool up=isBuy?profitSide:!profitSide;
   return NormalizeDouble(up?entryPrice*(1.0+factor):entryPrice*(1.0-factor),_Digits);
}

bool ModifyPositionSLTP(ulong ticket,double slPrice,double tpPrice)
{
   if(ticket==0||!PositionSelectByTicket(ticket)) return false;
   ENUM_POSITION_TYPE posType=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   bool isBuy=(posType==POSITION_TYPE_BUY);
   double sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP);
   if(slPrice>0)
   {
      slPrice=NormalizeDouble(slPrice,_Digits);
      if(!StopDistanceOK(isBuy,slPrice)) return false;
      sl=slPrice;
   }
   if(tpPrice>0) tp=NormalizeDouble(tpPrice,_Digits);
   MqlTradeRequest req;MqlTradeResult res;
   ZeroMemory(req);ZeroMemory(res);
   req.action=TRADE_ACTION_SLTP;
   req.position=ticket;
   req.symbol=PositionGetString(POSITION_SYMBOL);
   req.sl=sl;
   req.tp=tp;
   req.magic=(ulong)PositionGetInteger(POSITION_MAGIC);
   if(!OrderSend(req,res)) return false;
   return (res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_PLACED);
}

// Applies the staircase target for P2 (idx=0) or P3 (idx=1) on one side, once,
// based on the current stage for that side. Stage 0: nothing to do yet (P1 still
// open). Stage 1: both P2 and P3 get InpStairStage1SLPct/TPPct. Stage 2: P3 steps
// up to InpStairStage2SLPct/TPPct (P2 is expected closed by then).
void ApplyStaircaseLevel(bool isBuy,int idx)
{
   if(!InpStaircaseEnabled||(idx!=0&&idx!=1)) return;
   ulong ticket=isBuy?bTicket[idx]:sTicket[idx];
   if(ticket==0||!PositionSelectByTicket(ticket)) return;
   int stage=isBuy?bStairStage:sStairStage;
   if(stage<1) return;
   double slPct=InpStairStage1SLPct,tpPct=InpStairStage1TPPct;
   if(idx==1&&stage>=2){ slPct=InpStairStage2SLPct;tpPct=InpStairStage2TPPct; }
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   double slPrice=StaircasePrice(isBuy,entry,slPct,false);
   double tpPrice=StaircasePrice(isBuy,entry,tpPct,true);
   double curSL=PositionGetDouble(POSITION_SL),curTP=PositionGetDouble(POSITION_TP);
   if(MathAbs(curSL-slPrice)<=_Point&&MathAbs(curTP-tpPrice)<=_Point) return;
   ModifyPositionSLTP(ticket,slPrice,tpPrice);
}

bool PositionHasLockSL(ulong ticket,double lockMoney)
{
   if(ticket==0||!PositionSelectByTicket(ticket)) return false;
   ENUM_POSITION_TYPE posType=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   bool isBuy=(posType==POSITION_TYPE_BUY);
   double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
   double volume=PositionGetDouble(POSITION_VOLUME);
   double sl=PositionGetDouble(POSITION_SL);
   double desired=LockSLPrice(isBuy,openPrice,volume,lockMoney);
   if(sl<=0||desired<=0) return false;
   if(lockMoney>=0)
   {
      if(isBuy) return sl>=desired-_Point;
      return sl<=desired+_Point;
   }
   if(isBuy) return MathAbs(sl-desired)<=(_Point*2);
   return MathAbs(sl-desired)<=(_Point*2);
}

bool PositionHasSafeSL(ulong ticket)
{
   if(ticket==0||!PositionSelectByTicket(ticket)) return false;
   ENUM_POSITION_TYPE posType=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   bool isBuy=(posType==POSITION_TYPE_BUY);
   double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
   double sl=PositionGetDouble(POSITION_SL);
   if(sl<=0) return false;
   if(isBuy) return sl>openPrice;
   return sl<openPrice;
}

double CandleLockSLPrice(ulong ticket)
{
   if(ticket==0||!PositionSelectByTicket(ticket)) return 0;
   datetime posTime=(datetime)PositionGetInteger(POSITION_TIME);
   datetime currentM1=iTime(_Symbol,PERIOD_M1,0);
   if(currentM1<=0||currentM1<=posTime) return 0;

   ENUM_POSITION_TYPE posType=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   bool isBuy=(posType==POSITION_TYPE_BUY);
   double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
   double candidate=0;
   if(isBuy)
   {
      candidate=iLow(_Symbol,PERIOD_M1,1);
      if(candidate<=openPrice) return 0;
   }
   else
   {
      candidate=iHigh(_Symbol,PERIOD_M1,1);
      if(candidate>=openPrice) return 0;
   }
   return NormalizeDouble(candidate,_Digits);
}

bool TryProtectPosition(ulong ticket,double triggerMoney,double lockMoney)
{
   if(ticket==0||!PositionSelectByTicket(ticket)) return false;
   if(PositionHasSafeSL(ticket)) return true;
   if(PositionGetDouble(POSITION_PROFIT)>0)
   {
      double candleSL=CandleLockSLPrice(ticket);
      if(candleSL>0&&ModifyPositionSL(ticket,candleSL)) return true;
   }
   if(PositionGetDouble(POSITION_PROFIT)<triggerMoney) return false;
   if(PositionHasLockSL(ticket,lockMoney)||PositionHasSafeSL(ticket)) return true;
   ENUM_POSITION_TYPE posType=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   bool isBuy=(posType==POSITION_TYPE_BUY);
   double sl=LockSLPrice(isBuy,PositionGetDouble(POSITION_PRICE_OPEN),PositionGetDouble(POSITION_VOLUME),lockMoney);
   return ModifyPositionSL(ticket,sl);
}

double EABasketProfit(int dir=0)
{
   double total=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long magic=PositionGetInteger(POSITION_MAGIC);
      if(!IsThisEAMagic(magic)) continue;
      if(dir==1&&!IsBuyEngineMagic(magic)) continue;
      if(dir==-1&&!IsSellEngineMagic(magic)) continue;
      total+=PositionGetDouble(POSITION_PROFIT);
   }
   return total;
}

void CloseAllEAPositions(int dir=0)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long magic=PositionGetInteger(POSITION_MAGIC);
      if(!IsThisEAMagic(magic)) continue;
      if(dir==1&&!IsBuyEngineMagic(magic)) continue;
      if(dir==-1&&!IsSellEngineMagic(magic)) continue;
      ClosePosition(t);
   }
   DeleteEAOrders(dir);
}

void CheckBasketCloseSide(int dir)
{
   bool basketOn=(dir==1?bBasketOn:sBasketOn);
   bool basketClosed=(dir==1?bBasketClosed:sBasketClosed);
   double basketMoney=(dir==1?bBasketMoney:sBasketMoney);
   if(!basketOn||basketMoney<=0||basketClosed) return;
   double profit=EABasketProfit(dir);
   if(profit<basketMoney) return;
   CloseAllEAPositions(dir);
   if(dir==1){ bOn=false;bPaused=false;ResetBuyRunState();bBasketClosed=true; }
   else      { sOn=false;sPaused=false;ResetSellRunState();sBasketClosed=true; }
   gLastErrorText=(dir==1?"BUY":"SELL")+" basket close hit: EA positions closed at "+Dbl(profit,2)+". Restart is enabled.";
   SaveState();
}

void CheckBasketClose()
{
   CheckBasketCloseSide(1);
   CheckBasketCloseSide(-1);
}

void ApplyManualSLLock(int dir)
{
   double stopPrice=(dir==1?bStopPrice:sStopPrice);
   if(dir==1)
   {
      if(bStopOn)
      {
         bStopOn=false;
         gLastErrorText="BUY market SL disabled.";
      }
      else if(stopPrice>0)
      {
         bStopOn=true;
         gLastErrorText="BUY market SL enabled at "+DoubleToString(stopPrice,_Digits)+".";
      }
      else gLastErrorText="BUY market SL needs a price first.";
   }
   else
   {
      if(sStopOn)
      {
         sStopOn=false;
         gLastErrorText="SELL market SL disabled.";
      }
      else if(stopPrice>0)
      {
         sStopOn=true;
         gLastErrorText="SELL market SL enabled at "+DoubleToString(stopPrice,_Digits)+".";
      }
      else gLastErrorText="SELL market SL needs a price first.";
   }
   SaveState();
}

void CheckMarketStopLoss(double ask,double bid)
{
   bool changed=false;
   if(bStopOn&&bStopPrice>0&&bid<=NormalizeDouble(bStopPrice,_Digits))
   {
      CloseAllBuyPositions();
      bOn=false;bPaused=false;ResetBuyRunState();
      gLastErrorText="BUY market SL hit. All BUY-side EA trades closed.";
      changed=true;
   }
   if(sStopOn&&sStopPrice>0&&ask>=NormalizeDouble(sStopPrice,_Digits))
   {
      CloseAllSellPositions();
      sOn=false;sPaused=false;ResetSellRunState();
      gLastErrorText="SELL market SL hit. All SELL-side EA trades closed.";
      changed=true;
   }
   if(changed) SaveState();
}

string OppMarkName(ulong mainTicket)
{
   return GV_PREFIX+"opp_"+(string)mainTicket;
}

bool OppAlreadyOpened(ulong mainTicket)
{
   return GlobalVariableCheck(OppMarkName(mainTicket))&&GlobalVariableGet(OppMarkName(mainTicket))>0.5;
}

void MarkOppOpened(ulong mainTicket)
{
   GlobalVariableSet(OppMarkName(mainTicket),1);
}

bool OppOutstanding(long oppMagic)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)==oppMagic) return true;
   }
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);if(t==0||!OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC)==oppMagic) return true;
   }
   return false;
}

void ManageOppositeScalps()
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long magic=PositionGetInteger(POSITION_MAGIC);
      double profit=PositionGetDouble(POSITION_PROFIT);
      if(magic==BUY_OPP_MAGIC&&profit>=bOppMoney)
      {
         ClosePosition(t);
         continue;
      }
      if(magic==SELL_OPP_MAGIC&&profit>=sOppMoney)
      {
         ClosePosition(t);
         continue;
      }
   }

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      string cmt=PositionGetString(POSITION_COMMENT);
      if(StringLen(cmt)<2||StringSubstr(cmt,0,1)!="P") continue;
      if((int)StringToInteger(StringSubstr(cmt,1))<1) continue;
      long magic=PositionGetInteger(POSITION_MAGIC);
      double volume=PositionGetDouble(POSITION_VOLUME);
      double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);

      if(bOppOn&&magic==currBuyM&&!OppOutstanding(BUY_OPP_MAGIC))
      {
         double tpDist=PriceGap(bOppMoney);
         double entryDist=tpDist*0.50;
         if(tpDist>0&&entryDist>0)
         {
            double sellAt=NormalizeDouble(openPrice+entryDist,_Digits);
            double takeProfit=NormalizeDouble(sellAt-tpDist,_Digits);
            ulong order=PlaceSellLimitTP(volume,sellAt,takeProfit,"B+S",BUY_OPP_MAGIC);
            if(order>0){ gLastErrorText="B+S placed SELL LIMIT with TP."; }
         }
      }
      if(sOppOn&&magic==currSellM&&!OppOutstanding(SELL_OPP_MAGIC))
      {
         double tpDist=PriceGap(sOppMoney);
         double entryDist=tpDist*0.50;
         if(tpDist>0&&entryDist>0)
         {
            double buyAt=NormalizeDouble(openPrice-entryDist,_Digits);
            double takeProfit=NormalizeDouble(buyAt+tpDist,_Digits);
            ulong order=PlaceBuyLimitTP(volume,buyAt,takeProfit,"S+B",SELL_OPP_MAGIC);
            if(order>0){ gLastErrorText="S+B placed BUY LIMIT with TP."; }
         }
      }
   }
}

void RestartSideFromMarket(int dir)
{
   CaptureVisibleInputs();
   if(dir==1)
   {
      ResetBuyRunState();
      bOn=true;bPaused=false;bStart=0;bStartReached=true;bBasketClosed=false;
   }
   else
   {
      ResetSellRunState();
      sOn=true;sPaused=false;sStart=0;sStartReached=true;sBasketClosed=false;
   }
   RefreshInputs();
   gLastErrorText=(dir==1?"BUY":"SELL")+" restarted from current market with same settings.";
   SaveState();
}

void PauseBothAfterBadCloses(string reason)
{
   bPaused=true;sPaused=true;
   SetError("Auto pause: "+reason+". BUY and SELL paused. Trades NOT closed.");
}

void RegisterClosedProfit(bool isBuy,double profit)
{
   if(isBuy){ if(profit<=0)bBadCloses++; else bBadCloses=0; }
   else     { if(profit<=0)sBadCloses++; else sBadCloses=0; }
   if(bBadCloses>=BAD_CLOSE_LIMIT||sBadCloses>=BAD_CLOSE_LIMIT)
      PauseBothAfterBadCloses("3 continued loss/zero-profit closes");
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol) return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT) return;

   long magic=HistoryDealGetInteger(trans.deal,DEAL_MAGIC);
   ulong posId=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
   string comment=HistoryDealGetString(trans.deal,DEAL_COMMENT);
   ENUM_DEAL_REASON reason=(ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal,DEAL_REASON);
   double profit=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)
                +HistoryDealGetDouble(trans.deal,DEAL_SWAP)
                +HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
   bool mainBuyClose=(magic==currBuyM&&(posId==bTicket1||StringFind(comment,"P1")>=0));
   bool mainSellClose=(magic==currSellM&&(posId==sTicket1||StringFind(comment,"P1")>=0));
   if(InpStaircaseEnabled)
   {
      bool p2BuyClose=(magic==currBuyM&&StringFind(comment,"P2")>=0);
      bool p2SellClose=(magic==currSellM&&StringFind(comment,"P2")>=0);
      if(mainBuyClose&&bStairStage<1) bStairStage=1;
      if(mainSellClose&&sStairStage<1) sStairStage=1;
      if(p2BuyClose&&bStairStage<2) bStairStage=2;
      if(p2SellClose&&sStairStage<2) sStairStage=2;
   }
   if(reason==DEAL_REASON_SL&&profit>=0)
   {
      if(mainBuyClose)
      {
         bScalpPullbackActive=true;
         bScalpPullbackStart=TimeCurrent();
         bScalpPullbackRef=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      }
      if(mainSellClose)
      {
         sScalpPullbackActive=true;
         sScalpPullbackStart=TimeCurrent();
         sScalpPullbackRef=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      }
   }
   if(magic==currBuyM)  RegisterClosedProfit(true,profit);
   if(magic==currSellM) RegisterClosedProfit(false,profit);
   SaveState();
}

//==========================================================================
//  SAVE / RESTORE
//==========================================================================
void SaveState()
{
   GlobalVariableSet(GV_PREFIX+"currBuyM",(double)currBuyM);
   GlobalVariableSet(GV_PREFIX+"currSellM",(double)currSellM);
   GlobalVariableSet(GV_PREFIX+"period",(double)_Period);
   GlobalVariableSet(GV_PREFIX+"uiCollapsed",uiCollapsed?1:0);
   GlobalVariableSet(GV_PREFIX+"ospExpanded",ospExpanded?1:0);
   GlobalVariableSet(GV_PREFIX+"bProtectMoney",bProtectMoney);
   GlobalVariableSet(GV_PREFIX+"sProtectMoney",sProtectMoney);
   GlobalVariableSet(GV_PREFIX+"bLockMoney",bLockMoney);
   GlobalVariableSet(GV_PREFIX+"sLockMoney",sLockMoney);
   GlobalVariableSet(GV_PREFIX+"bBasketMoney",bBasketMoney);
   GlobalVariableSet(GV_PREFIX+"sBasketMoney",sBasketMoney);
   GlobalVariableSet(GV_PREFIX+"bBasketOn",bBasketOn?1:0);
   GlobalVariableSet(GV_PREFIX+"sBasketOn",sBasketOn?1:0);
   GlobalVariableSet(GV_PREFIX+"bStopPrice",bStopPrice);
   GlobalVariableSet(GV_PREFIX+"sStopPrice",sStopPrice);
   GlobalVariableSet(GV_PREFIX+"bStopOn",bStopOn?1:0);
   GlobalVariableSet(GV_PREFIX+"sStopOn",sStopOn?1:0);
   GlobalVariableSet(GV_PREFIX+"bBasketClosed",bBasketClosed?1:0);
   GlobalVariableSet(GV_PREFIX+"sBasketClosed",sBasketClosed?1:0);
   GlobalVariableSet(GV_PREFIX+"bOppOn",bOppOn?1:0);
   GlobalVariableSet(GV_PREFIX+"sOppOn",sOppOn?1:0);
   GlobalVariableSet(GV_PREFIX+"bOppMoney",bOppMoney);
   GlobalVariableSet(GV_PREFIX+"sOppMoney",sOppMoney);
   GlobalVariableSet(GV_PREFIX+"bAutoSR",bAutoSR?1:0);
   GlobalVariableSet(GV_PREFIX+"sAutoSR",sAutoSR?1:0);

   GlobalVariableSet(GV_PREFIX+"bOn",bOn?1:0);GlobalVariableSet(GV_PREFIX+"bPaused",bPaused?1:0);
   GlobalVariableSet(GV_PREFIX+"bRepeat",bRepeat?1:0);GlobalVariableSet(GV_PREFIX+"bStartReached",bStartReached?1:0);
   GlobalVariableSet(GV_PREFIX+"bStartAbove",bStartAbove?1:0);GlobalVariableSet(GV_PREFIX+"bStart",bStart);
   GlobalVariableSet(GV_PREFIX+"bTarget",bTarget);GlobalVariableSet(GV_PREFIX+"bLot1",bLot1);
   GlobalVariableSet(GV_PREFIX+"bBadCloses",bBadCloses);
   GlobalVariableSet(GV_PREFIX+"bStairStage",bStairStage);
   GlobalVariableSet(GV_PREFIX+"bGapCount",bGapCount);
   GlobalVariableSet(GV_PREFIX+"bStuck1",bStuck1);GlobalVariableSet(GV_PREFIX+"bScalp1",bScalp1);
   GlobalVariableSet(GV_PREFIX+"bScalpPBActive",bScalpPullbackActive?1:0);
   GlobalVariableSet(GV_PREFIX+"bScalpPBStart",(double)bScalpPullbackStart);
   GlobalVariableSet(GV_PREFIX+"bScalpPBRef",bScalpPullbackRef);
   GlobalVariableSet(GV_PREFIX+"bGap2PBStart",(double)bGap2PullbackStart);

   GlobalVariableSet(GV_PREFIX+"sOn",sOn?1:0);GlobalVariableSet(GV_PREFIX+"sPaused",sPaused?1:0);
   GlobalVariableSet(GV_PREFIX+"sRepeat",sRepeat?1:0);GlobalVariableSet(GV_PREFIX+"sStartReached",sStartReached?1:0);
   GlobalVariableSet(GV_PREFIX+"sStartAbove",sStartAbove?1:0);GlobalVariableSet(GV_PREFIX+"sStart",sStart);
   GlobalVariableSet(GV_PREFIX+"sTarget",sTarget);GlobalVariableSet(GV_PREFIX+"sLot1",sLot1);
   GlobalVariableSet(GV_PREFIX+"sBadCloses",sBadCloses);
   GlobalVariableSet(GV_PREFIX+"sStairStage",sStairStage);
   GlobalVariableSet(GV_PREFIX+"sGapCount",sGapCount);
   GlobalVariableSet(GV_PREFIX+"sStuck1",sStuck1);GlobalVariableSet(GV_PREFIX+"sScalp1",sScalp1);
   GlobalVariableSet(GV_PREFIX+"sScalpPBActive",sScalpPullbackActive?1:0);
   GlobalVariableSet(GV_PREFIX+"sScalpPBStart",(double)sScalpPullbackStart);
   GlobalVariableSet(GV_PREFIX+"sScalpPBRef",sScalpPullbackRef);
   GlobalVariableSet(GV_PREFIX+"sGap2PBStart",(double)sGap2PullbackStart);

   for(int i=0;i<bGapCount;i++)
   {
      string k=(string)i;
      GlobalVariableSet(GV_PREFIX+"bGap"+k,bGap[i]);GlobalVariableSet(GV_PREFIX+"bLot"+k,bLot[i]);
      GlobalVariableSet(GV_PREFIX+"bTP"+k,bTP[i]);GlobalVariableSet(GV_PREFIX+"bGapOn"+k,bGapOn[i]?1:0);
      GlobalVariableSet(GV_PREFIX+"bLock"+k,bLock[i]);
      GlobalVariableSet(GV_PREFIX+"bActive"+k,bActive[i]?1:0);GlobalVariableSet(GV_PREFIX+"bStuck"+k,bStuck[i]);
      GlobalVariableSet(GV_PREFIX+"bReturn"+k,bReturnTarget[i]);GlobalVariableSet(GV_PREFIX+"bArmed"+k,bArmedPrice[i]);
      GlobalVariableSet(GV_PREFIX+"bScalps"+k,bScalps[i]);
   }
   for(int i=0;i<sGapCount;i++)
   {
      string k=(string)i;
      GlobalVariableSet(GV_PREFIX+"sGap"+k,sGap[i]);GlobalVariableSet(GV_PREFIX+"sLot"+k,sLot[i]);
      GlobalVariableSet(GV_PREFIX+"sTP"+k,sTP[i]);GlobalVariableSet(GV_PREFIX+"sGapOn"+k,sGapOn[i]?1:0);
      GlobalVariableSet(GV_PREFIX+"sLock"+k,sLock[i]);
      GlobalVariableSet(GV_PREFIX+"sActive"+k,sActive[i]?1:0);GlobalVariableSet(GV_PREFIX+"sStuck"+k,sStuck[i]);
      GlobalVariableSet(GV_PREFIX+"sReturn"+k,sReturnTarget[i]);GlobalVariableSet(GV_PREFIX+"sArmed"+k,sArmedPrice[i]);
      GlobalVariableSet(GV_PREFIX+"sScalps"+k,sScalps[i]);
   }
}

void RestoreState()
{
   currBuyM=BASE_BUY_MAGIC;currSellM=BASE_SELL_MAGIC;
   ResizeBuyGaps(DEFAULT_GAPS);ResizeSellGaps(DEFAULT_GAPS);

   if(!GlobalVariableCheck(GV_PREFIX+"currBuyM")) return;
   currBuyM=(long)GlobalVariableGet(GV_PREFIX+"currBuyM");
   currSellM=(long)GlobalVariableGet(GV_PREFIX+"currSellM");
   uiCollapsed=GlobalVariableCheck(GV_PREFIX+"uiCollapsed")&&GlobalVariableGet(GV_PREFIX+"uiCollapsed")>0.5;
   ospExpanded=GlobalVariableCheck(GV_PREFIX+"ospExpanded")&&GlobalVariableGet(GV_PREFIX+"ospExpanded")>0.5;
   bProtectMoney=GlobalVariableCheck(GV_PREFIX+"bProtectMoney")?GlobalVariableGet(GV_PREFIX+"bProtectMoney"):2.00;
   sProtectMoney=GlobalVariableCheck(GV_PREFIX+"sProtectMoney")?GlobalVariableGet(GV_PREFIX+"sProtectMoney"):2.00;
   bLockMoney=GlobalVariableCheck(GV_PREFIX+"bLockMoney")?GlobalVariableGet(GV_PREFIX+"bLockMoney"):1.00;
   sLockMoney=GlobalVariableCheck(GV_PREFIX+"sLockMoney")?GlobalVariableGet(GV_PREFIX+"sLockMoney"):1.00;
   bBasketMoney=GlobalVariableCheck(GV_PREFIX+"bBasketMoney")?GlobalVariableGet(GV_PREFIX+"bBasketMoney"):100.00;
   sBasketMoney=GlobalVariableCheck(GV_PREFIX+"sBasketMoney")?GlobalVariableGet(GV_PREFIX+"sBasketMoney"):100.00;
   bBasketOn=GlobalVariableCheck(GV_PREFIX+"bBasketOn")&&GlobalVariableGet(GV_PREFIX+"bBasketOn")>0.5;
   sBasketOn=GlobalVariableCheck(GV_PREFIX+"sBasketOn")&&GlobalVariableGet(GV_PREFIX+"sBasketOn")>0.5;
   bStopPrice=GlobalVariableCheck(GV_PREFIX+"bStopPrice")?GlobalVariableGet(GV_PREFIX+"bStopPrice"):0;
   sStopPrice=GlobalVariableCheck(GV_PREFIX+"sStopPrice")?GlobalVariableGet(GV_PREFIX+"sStopPrice"):0;
   bStopOn=GlobalVariableCheck(GV_PREFIX+"bStopOn")&&GlobalVariableGet(GV_PREFIX+"bStopOn")>0.5;
   sStopOn=GlobalVariableCheck(GV_PREFIX+"sStopOn")&&GlobalVariableGet(GV_PREFIX+"sStopOn")>0.5;
   bBasketClosed=GlobalVariableCheck(GV_PREFIX+"bBasketClosed")&&GlobalVariableGet(GV_PREFIX+"bBasketClosed")>0.5;
   sBasketClosed=GlobalVariableCheck(GV_PREFIX+"sBasketClosed")&&GlobalVariableGet(GV_PREFIX+"sBasketClosed")>0.5;
   bOppOn=GlobalVariableCheck(GV_PREFIX+"bOppOn")&&GlobalVariableGet(GV_PREFIX+"bOppOn")>0.5;
   sOppOn=GlobalVariableCheck(GV_PREFIX+"sOppOn")&&GlobalVariableGet(GV_PREFIX+"sOppOn")>0.5;
   bOppMoney=GlobalVariableCheck(GV_PREFIX+"bOppMoney")?GlobalVariableGet(GV_PREFIX+"bOppMoney"):1.00;
   sOppMoney=GlobalVariableCheck(GV_PREFIX+"sOppMoney")?GlobalVariableGet(GV_PREFIX+"sOppMoney"):1.00;
   bAutoSR=GlobalVariableCheck(GV_PREFIX+"bAutoSR")&&GlobalVariableGet(GV_PREFIX+"bAutoSR")>0.5;
   sAutoSR=GlobalVariableCheck(GV_PREFIX+"sAutoSR")&&GlobalVariableGet(GV_PREFIX+"sAutoSR")>0.5;

   bOn=GlobalVariableGet(GV_PREFIX+"bOn")>0.5;bPaused=GlobalVariableGet(GV_PREFIX+"bPaused")>0.5;
   bRepeat=GlobalVariableGet(GV_PREFIX+"bRepeat")>0.5;
   bStartReached=GlobalVariableCheck(GV_PREFIX+"bStartReached")&&GlobalVariableGet(GV_PREFIX+"bStartReached")>0.5;
   bStartAbove=GlobalVariableCheck(GV_PREFIX+"bStartAbove")&&GlobalVariableGet(GV_PREFIX+"bStartAbove")>0.5;
   bStart=GlobalVariableGet(GV_PREFIX+"bStart");bTarget=GlobalVariableGet(GV_PREFIX+"bTarget");
   bLot1=GlobalVariableGet(GV_PREFIX+"bLot1");
   bBadCloses=(int)GlobalVariableGet(GV_PREFIX+"bBadCloses");
   bStairStage=GlobalVariableCheck(GV_PREFIX+"bStairStage")?(int)GlobalVariableGet(GV_PREFIX+"bStairStage"):0;
   bStuck1=GlobalVariableCheck(GV_PREFIX+"bStuck1")?GlobalVariableGet(GV_PREFIX+"bStuck1"):0;
   bScalp1=GlobalVariableCheck(GV_PREFIX+"bScalp1")?(int)GlobalVariableGet(GV_PREFIX+"bScalp1"):0;
   bScalpPullbackActive=GlobalVariableCheck(GV_PREFIX+"bScalpPBActive")&&GlobalVariableGet(GV_PREFIX+"bScalpPBActive")>0.5;
   bScalpPullbackStart=GlobalVariableCheck(GV_PREFIX+"bScalpPBStart")?(datetime)GlobalVariableGet(GV_PREFIX+"bScalpPBStart"):0;
   bScalpPullbackRef=GlobalVariableCheck(GV_PREFIX+"bScalpPBRef")?GlobalVariableGet(GV_PREFIX+"bScalpPBRef"):0;
   bGap2PullbackStart=GlobalVariableCheck(GV_PREFIX+"bGap2PBStart")?(datetime)GlobalVariableGet(GV_PREFIX+"bGap2PBStart"):0;

   sOn=GlobalVariableGet(GV_PREFIX+"sOn")>0.5;sPaused=GlobalVariableGet(GV_PREFIX+"sPaused")>0.5;
   sRepeat=GlobalVariableGet(GV_PREFIX+"sRepeat")>0.5;
   sStartReached=GlobalVariableCheck(GV_PREFIX+"sStartReached")&&GlobalVariableGet(GV_PREFIX+"sStartReached")>0.5;
   sStartAbove=GlobalVariableCheck(GV_PREFIX+"sStartAbove")&&GlobalVariableGet(GV_PREFIX+"sStartAbove")>0.5;
   sStart=GlobalVariableGet(GV_PREFIX+"sStart");sTarget=GlobalVariableGet(GV_PREFIX+"sTarget");
   sLot1=GlobalVariableGet(GV_PREFIX+"sLot1");
   sBadCloses=(int)GlobalVariableGet(GV_PREFIX+"sBadCloses");
   sStairStage=GlobalVariableCheck(GV_PREFIX+"sStairStage")?(int)GlobalVariableGet(GV_PREFIX+"sStairStage"):0;
   sStuck1=GlobalVariableCheck(GV_PREFIX+"sStuck1")?GlobalVariableGet(GV_PREFIX+"sStuck1"):0;
   sScalp1=GlobalVariableCheck(GV_PREFIX+"sScalp1")?(int)GlobalVariableGet(GV_PREFIX+"sScalp1"):0;
   sScalpPullbackActive=GlobalVariableCheck(GV_PREFIX+"sScalpPBActive")&&GlobalVariableGet(GV_PREFIX+"sScalpPBActive")>0.5;
   sScalpPullbackStart=GlobalVariableCheck(GV_PREFIX+"sScalpPBStart")?(datetime)GlobalVariableGet(GV_PREFIX+"sScalpPBStart"):0;
   sScalpPullbackRef=GlobalVariableCheck(GV_PREFIX+"sScalpPBRef")?GlobalVariableGet(GV_PREFIX+"sScalpPBRef"):0;
   sGap2PullbackStart=GlobalVariableCheck(GV_PREFIX+"sGap2PBStart")?(datetime)GlobalVariableGet(GV_PREFIX+"sGap2PBStart"):0;

   int bc=GlobalVariableCheck(GV_PREFIX+"bGapCount")?(int)GlobalVariableGet(GV_PREFIX+"bGapCount"):DEFAULT_GAPS;
   int sc=GlobalVariableCheck(GV_PREFIX+"sGapCount")?(int)GlobalVariableGet(GV_PREFIX+"sGapCount"):DEFAULT_GAPS;
   ResizeBuyGaps(bc);ResizeSellGaps(sc);

   for(int i=0;i<bGapCount;i++)
   {
      string k=(string)i;
      if(GlobalVariableCheck(GV_PREFIX+"bGap"+k)) bGap[i]=GlobalVariableGet(GV_PREFIX+"bGap"+k);
      if(GlobalVariableCheck(GV_PREFIX+"bLot"+k)) bLot[i]=GlobalVariableGet(GV_PREFIX+"bLot"+k);
      if(GlobalVariableCheck(GV_PREFIX+"bTP"+k)) bTP[i]=GlobalVariableGet(GV_PREFIX+"bTP"+k);
      bLock[i]=GlobalVariableCheck(GV_PREFIX+"bLock"+k)?GlobalVariableGet(GV_PREFIX+"bLock"+k):DEFAULT_GAP_LOCK;
      bGapOn[i]=!GlobalVariableCheck(GV_PREFIX+"bGapOn"+k)||GlobalVariableGet(GV_PREFIX+"bGapOn"+k)>0.5;
      bActive[i]=GlobalVariableCheck(GV_PREFIX+"bActive"+k)&&GlobalVariableGet(GV_PREFIX+"bActive"+k)>0.5;
      bStuck[i]=GlobalVariableCheck(GV_PREFIX+"bStuck"+k)?GlobalVariableGet(GV_PREFIX+"bStuck"+k):0;
      bReturnTarget[i]=GlobalVariableCheck(GV_PREFIX+"bReturn"+k)?GlobalVariableGet(GV_PREFIX+"bReturn"+k):0;
      bArmedPrice[i]=GlobalVariableCheck(GV_PREFIX+"bArmed"+k)?GlobalVariableGet(GV_PREFIX+"bArmed"+k):0;
      bScalps[i]=GlobalVariableCheck(GV_PREFIX+"bScalps"+k)?(int)GlobalVariableGet(GV_PREFIX+"bScalps"+k):0;
   }
   for(int i=0;i<sGapCount;i++)
   {
      string k=(string)i;
      if(GlobalVariableCheck(GV_PREFIX+"sGap"+k)) sGap[i]=GlobalVariableGet(GV_PREFIX+"sGap"+k);
      if(GlobalVariableCheck(GV_PREFIX+"sLot"+k)) sLot[i]=GlobalVariableGet(GV_PREFIX+"sLot"+k);
      if(GlobalVariableCheck(GV_PREFIX+"sTP"+k)) sTP[i]=GlobalVariableGet(GV_PREFIX+"sTP"+k);
      sLock[i]=GlobalVariableCheck(GV_PREFIX+"sLock"+k)?GlobalVariableGet(GV_PREFIX+"sLock"+k):DEFAULT_GAP_LOCK;
      sGapOn[i]=!GlobalVariableCheck(GV_PREFIX+"sGapOn"+k)||GlobalVariableGet(GV_PREFIX+"sGapOn"+k)>0.5;
      sActive[i]=GlobalVariableCheck(GV_PREFIX+"sActive"+k)&&GlobalVariableGet(GV_PREFIX+"sActive"+k)>0.5;
      sStuck[i]=GlobalVariableCheck(GV_PREFIX+"sStuck"+k)?GlobalVariableGet(GV_PREFIX+"sStuck"+k):0;
      sReturnTarget[i]=GlobalVariableCheck(GV_PREFIX+"sReturn"+k)?GlobalVariableGet(GV_PREFIX+"sReturn"+k):0;
      sArmedPrice[i]=GlobalVariableCheck(GV_PREFIX+"sArmed"+k)?GlobalVariableGet(GV_PREFIX+"sArmed"+k):0;
      sScalps[i]=GlobalVariableCheck(GV_PREFIX+"sScalps"+k)?(int)GlobalVariableGet(GV_PREFIX+"sScalps"+k):0;
   }
}

//==========================================================================
//  INPUT SYNC / VALIDATION
//==========================================================================
double ObjNum(string name)
{
   if(ObjectFind(0,name)<0) return 0;
   return StringToDouble(ObjectGetString(0,name,OBJPROP_TEXT));
}

void SetObjText(string name,string text)
{
   if(ObjectFind(0,name)>=0) ObjectSetString(0,name,OBJPROP_TEXT,text);
}

string CompactPrice(double value)
{
   if(value<=0) return "0";
   string text=DoubleToString(NormalizeDouble(value,_Digits),_Digits);
   int dot=StringFind(text,".");
   if(dot>=0)
   {
      while(StringLen(text)>dot+1&&StringSubstr(text,StringLen(text)-1,1)=="0")
         text=StringSubstr(text,0,StringLen(text)-1);
      if(StringSubstr(text,StringLen(text)-1,1)==".")
         text=StringSubstr(text,0,StringLen(text)-1);
   }
   return text;
}

double DefaultGapLotValue()
{
   double lot=NormalizeLot(DEFAULT_GAP_LOT);
   if(lot<=0) lot=NormalizeLot(minLot);
   return lot;
}

bool ProSTargetLooksLikePrice(bool isBuy,double target)
{
   if(target<=0) return false;
   double price=SymbolInfoDouble(_Symbol,isBuy?SYMBOL_ASK:SYMBOL_BID);
   if(price>=InpAbsoluteGapPriceLevel&&target<InpAbsoluteGapPriceLevel) return false;
   return true;
}

bool GapValuesValid(bool isBuy,int index,double gap,double lot,double tp,double lock,string &reason)
{
   int level=index+2;
   reason="";
   if(IsProSIndex(index))
   {
      if(!ProSTargetLooksLikePrice(isBuy,tp)) reason="ProS target must be a price";
   }
   else if(level==2)
   {
      if(gap<0) reason="Gap2 must be 0 or higher";
   }
   else if(gap<=0)
      reason="Gap"+(string)level+" must be > 0";

   if(reason=="")
   {
      double normalizedLot=NormalizeLot(lot);
      if(normalizedLot<=0||lot<minLot||lot>maxLot) reason="Lot"+(string)level+" outside broker limits";
      else if(tp<=0) reason="Profit"+(string)level+" must be > 0";
      else if(lock<=0) reason="Lock"+(string)level+" must be > 0";
   }
   return reason=="";
}

void RepairGapValues(bool isBuy,int index,double &gap,double &lot,double &tp,double &lock)
{
   int level=index+2;
   if(IsProSIndex(index))
   {
      if(!ProSTargetLooksLikePrice(isBuy,tp)) tp=DefaultProSTarget(isBuy);
   }
   else if((level==2&&gap<0)||(level>2&&gap<=0))
      gap=DEFAULT_GAP_VALUE;
   if(NormalizeLot(lot)<=0||lot<minLot||lot>maxLot) lot=DefaultGapLotValue();
   if(tp<=0) tp=DEFAULT_GAP_PROFIT;
   if(lock<=0) lock=DEFAULT_GAP_LOCK;
}

void SetGapInputTexts(bool isBuy,int index,double gap,double lot,double tp,double lock)
{
   string prefix=isBuy?"UI_B_":"UI_S_";
   string k=(string)index;
   SetObjText(prefix+"GAP"+k,Dbl(gap,2));
   SetObjText(prefix+"LOT"+k,Dbl(lot,2));
   SetObjText(prefix+"PROFIT"+k,Dbl(tp,2));
   SetObjText(prefix+"LOCK_G"+k,Dbl(lock,2));
}

void SwitchGapOff(bool isBuy,int index,string reason)
{
   int level=index+2;
   string side=isBuy?"BUY":"SELL";
   if(isBuy)
   {
      bGapOn[index]=false;
      if(bTicket[index]==0)
      {
         bActive[index]=false;bReturnTarget[index]=0;bArmedPrice[index]=0;
         if(index==0) bGap2PullbackStart=0;
      }
   }
   else
   {
      sGapOn[index]=false;
      if(sTicket[index]==0)
      {
         sActive[index]=false;sReturnTarget[index]=0;sArmedPrice[index]=0;
         if(index==0) sGap2PullbackStart=0;
      }
   }
   gLastErrorText=side+": "+reason+"; Gap"+(string)level+" switched OFF and defaults restored.";
   Print(gLastErrorText);
}

bool GapInputValid(bool isBuy,int index)
{
   string prefix=isBuy?"UI_B_":"UI_S_";
   string k=(string)index;
   double gap=ObjNum(prefix+"GAP"+k);
   double lot=ObjNum(prefix+"LOT"+k);
   double tp=ObjNum(prefix+"PROFIT"+k);
   double lock=ObjNum(prefix+"LOCK_G"+k);
   string reason="";
   return GapValuesValid(isBuy,index,gap,lot,tp,lock,reason);
}

void SanitizeStoredGapRows()
{
   for(int i=0;i<bGapCount;i++)
   {
      string reason="";
      if(!GapValuesValid(true,i,bGap[i],bLot[i],bTP[i],bLock[i],reason))
      {
         RepairGapValues(true,i,bGap[i],bLot[i],bTP[i],bLock[i]);
         SwitchGapOff(true,i,reason);
      }
   }
   for(int i=0;i<sGapCount;i++)
   {
      string reason="";
      if(!GapValuesValid(false,i,sGap[i],sLot[i],sTP[i],sLock[i],reason))
      {
         RepairGapValues(false,i,sGap[i],sLot[i],sTP[i],sLock[i]);
         SwitchGapOff(false,i,reason);
      }
   }
}

bool ValidateSide(bool isBuy,double start,double target,double lot1)
{
   string side=isBuy?"BUY":"SELL";
   if(lot1<minLot||lot1>maxLot){ SetError(side+": Main lot outside broker limits."); return false; }
   if(isBuy && target>0&&start>0&&target<=start){ SetError("BUY: Target must be ABOVE Start."); return false; }
   if(!isBuy&& target>0&&start>0&&target>=start){ SetError("SELL: Target must be BELOW Start."); return false; }
   int count=isBuy?bGapCount:sGapCount;
   for(int i=0;i<count;i++)
   {
      double gap=isBuy?ObjNum("UI_B_GAP"+(string)i):ObjNum("UI_S_GAP"+(string)i);
      double lot=isBuy?ObjNum("UI_B_LOT"+(string)i):ObjNum("UI_S_LOT"+(string)i);
      double tp =isBuy?ObjNum("UI_B_PROFIT"+(string)i):ObjNum("UI_S_PROFIT"+(string)i);
      double lock=isBuy?ObjNum("UI_B_LOCK_G"+(string)i):ObjNum("UI_S_LOCK_G"+(string)i);
      string reason="";
      if(!GapValuesValid(isBuy,i,gap,lot,tp,lock,reason))
      {
         RepairGapValues(isBuy,i,gap,lot,tp,lock);
         if(isBuy){ bGap[i]=gap;bLot[i]=lot;bTP[i]=tp;bLock[i]=lock; }
         else     { sGap[i]=gap;sLot[i]=lot;sTP[i]=tp;sLock[i]=lock; }
         SetGapInputTexts(isBuy,i,gap,lot,tp,lock);
         SwitchGapOff(isBuy,i,reason);
      }
   }
   return true;
}

bool SyncBuy()
{
   double start=ObjNum("UI_B_START_PRICE"),target=ObjNum("UI_B_TARGET_PRICE");
   double lot1=ObjectFind(0,"UI_B_MAIN_LOT")>=0?ObjNum("UI_B_MAIN_LOT"):bLot1;
   if(start<0) start=0;if(target<0) target=0;
   if(bAutoSR){ start=bStart;target=bTarget; }
   if(!ValidateSide(true,start,target,lot1)) return false;
   bStart=start>0?NormalizeDouble(start,_Digits):0;bTarget=target;
   bLot1=NormalizeLot(lot1);
   for(int i=0;i<bGapCount;i++)
   {
      double newGap=ObjNum("UI_B_GAP"+(string)i);
      double newTP=ObjNum("UI_B_PROFIT"+(string)i);
      if(IsProSIndex(i)&&bTicket[i]==0&&(MathAbs(newGap-bGap[i])>_Point||MathAbs(newTP-bTP[i])>_Point))
      {
         bActive[i]=false;bArmedPrice[i]=0;bReturnTarget[i]=0;
      }
      bGap[i]=newGap;
      bLot[i]=NormalizeLot(ObjNum("UI_B_LOT"+(string)i));
      bTP[i]=newTP;
      bLock[i]=ObjNum("UI_B_LOCK_G"+(string)i);
   }
   gLastErrorText="";
   SaveState();
   return true;
}

bool SyncSell()
{
   double start=ObjNum("UI_S_START_PRICE"),target=ObjNum("UI_S_TARGET_PRICE");
   double lot1=ObjectFind(0,"UI_S_MAIN_LOT")>=0?ObjNum("UI_S_MAIN_LOT"):sLot1;
   if(start<0) start=0;if(target<0) target=0;
   if(sAutoSR){ start=sStart;target=sTarget; }
   if(!ValidateSide(false,start,target,lot1)) return false;
   sStart=start>0?NormalizeDouble(start,_Digits):0;sTarget=target;
   sLot1=NormalizeLot(lot1);
   for(int i=0;i<sGapCount;i++)
   {
      double newGap=ObjNum("UI_S_GAP"+(string)i);
      double newTP=ObjNum("UI_S_PROFIT"+(string)i);
      if(IsProSIndex(i)&&sTicket[i]==0&&(MathAbs(newGap-sGap[i])>_Point||MathAbs(newTP-sTP[i])>_Point))
      {
         sActive[i]=false;sArmedPrice[i]=0;sReturnTarget[i]=0;
      }
      sGap[i]=newGap;
      sLot[i]=NormalizeLot(ObjNum("UI_S_LOT"+(string)i));
      sTP[i]=newTP;
      sLock[i]=ObjNum("UI_S_LOCK_G"+(string)i);
   }
   gLastErrorText="";
   SaveState();
   return true;
}

bool SyncControlInputs()
{
   if(ObjectFind(0,"UI_B_PROTECT")>=0){ double v=ObjNum("UI_B_PROTECT"); if(v>0)bProtectMoney=v; }
   if(ObjectFind(0,"UI_S_PROTECT")>=0){ double v=ObjNum("UI_S_PROTECT"); if(v>0)sProtectMoney=v; }
   if(ObjectFind(0,"UI_B_LOCK")>=0){ double v=ObjNum("UI_B_LOCK"); if(v>0)bLockMoney=v; }
   if(ObjectFind(0,"UI_S_LOCK")>=0){ double v=ObjNum("UI_S_LOCK"); if(v>0)sLockMoney=v; }
   if(ObjectFind(0,"UI_B_BASKET")>=0){ double v=ObjNum("UI_B_BASKET"); if(v>=0)bBasketMoney=v; }
   if(ObjectFind(0,"UI_S_BASKET")>=0){ double v=ObjNum("UI_S_BASKET"); if(v>=0)sBasketMoney=v; }
   if(ObjectFind(0,"UI_B_SL_LOCK")>=0){ double v=ObjNum("UI_B_SL_LOCK"); if(v>=0)bStopPrice=v; }
   if(ObjectFind(0,"UI_S_SL_LOCK")>=0){ double v=ObjNum("UI_S_SL_LOCK"); if(v>=0)sStopPrice=v; }
   if(ObjectFind(0,"UI_B_OPP_MONEY")>=0){ double v=ObjNum("UI_B_OPP_MONEY"); if(v>0)bOppMoney=v; }
   if(ObjectFind(0,"UI_S_OPP_MONEY")>=0){ double v=ObjNum("UI_S_OPP_MONEY"); if(v>0)sOppMoney=v; }
   SaveState();
   return true;
}

void RefreshInputs()
{
   SetObjText("UI_B_START_PRICE",CompactPrice(bStart));
   SetObjText("UI_B_TARGET_PRICE",CompactPrice(bTarget));
   SetObjText("UI_B_LOT1",Dbl(bLot1,2));
   SetObjText("UI_S_START_PRICE",CompactPrice(sStart));
   SetObjText("UI_S_TARGET_PRICE",CompactPrice(sTarget));
   SetObjText("UI_S_LOT1",Dbl(sLot1,2));
   for(int i=0;i<bGapCount;i++)
   {
      SetObjText("UI_B_GAP"+(string)i,Dbl(bGap[i],2));
      SetObjText("UI_B_LOT"+(string)i,Dbl(bLot[i],2));
      SetObjText("UI_B_PROFIT"+(string)i,Dbl(bTP[i],2));
      SetObjText("UI_B_LOCK_G"+(string)i,Dbl(bLock[i],2));
   }
   for(int i=0;i<sGapCount;i++)
   {
      SetObjText("UI_S_GAP"+(string)i,Dbl(sGap[i],2));
      SetObjText("UI_S_LOT"+(string)i,Dbl(sLot[i],2));
      SetObjText("UI_S_PROFIT"+(string)i,Dbl(sTP[i],2));
      SetObjText("UI_S_LOCK_G"+(string)i,Dbl(sLock[i],2));
   }
   SetObjText("UI_B_MAIN_LOT",Dbl(bLot1>0?bLot1:0.01,2));
   SetObjText("UI_S_MAIN_LOT",Dbl(sLot1>0?sLot1:0.01,2));
   SetObjText("UI_B_PROTECT",Dbl(bProtectMoney,2));
   SetObjText("UI_S_PROTECT",Dbl(sProtectMoney,2));
   SetObjText("UI_B_LOCK",Dbl(bLockMoney,2));
   SetObjText("UI_S_LOCK",Dbl(sLockMoney,2));
   SetObjText("UI_B_BASKET",Dbl(bBasketMoney,2));
   SetObjText("UI_S_BASKET",Dbl(sBasketMoney,2));
   SetObjText("UI_B_SL_LOCK",CompactPrice(bStopPrice));
   SetObjText("UI_S_SL_LOCK",CompactPrice(sStopPrice));
   SetObjText("UI_B_OPP_MONEY",Dbl(bOppMoney,2));
   SetObjText("UI_S_OPP_MONEY",Dbl(sOppMoney,2));
}

//==========================================================================
//  AUTO SUPPORT/RESISTANCE
//==========================================================================
// Nearest confirmed swing high above `price`, scanning this chart's timeframe.
// A swing high needs InpSRFractalWidth bars lower on both sides (classic fractal).
// Returns 0 if none found within InpSRLookbackBars (caller should leave the
// existing target untouched rather than treat 0 as a real price).
double FindSwingResistanceAbove(double price)
{
   int width=MathMax(1,InpSRFractalWidth);
   int bars=iBars(_Symbol,_Period);
   int maxShift=MathMin(InpSRLookbackBars,bars-1-width);
   double best=0;
   for(int shift=1+width;shift<=maxShift;shift++)
   {
      double h=iHigh(_Symbol,_Period,shift);
      if(h<=price) continue;
      bool isSwing=true;
      for(int k=1;k<=width;k++)
      {
         if(iHigh(_Symbol,_Period,shift-k)>=h||iHigh(_Symbol,_Period,shift+k)>=h){ isSwing=false;break; }
      }
      if(isSwing&&(best<=0||h<best)) best=h;
   }
   return best;
}

// Nearest confirmed swing low below `price`. Mirror of FindSwingResistanceAbove.
double FindSwingSupportBelow(double price)
{
   int width=MathMax(1,InpSRFractalWidth);
   int bars=iBars(_Symbol,_Period);
   int maxShift=MathMin(InpSRLookbackBars,bars-1-width);
   double best=0;
   for(int shift=1+width;shift<=maxShift;shift++)
   {
      double l=iLow(_Symbol,_Period,shift);
      if(l>=price) continue;
      bool isSwing=true;
      for(int k=1;k<=width;k++)
      {
         if(iLow(_Symbol,_Period,shift-k)<=l||iLow(_Symbol,_Period,shift+k)<=l){ isSwing=false;break; }
      }
      if(isSwing&&(best<=0||l>best)) best=l;
   }
   return best;
}

// Recomputes Target from swing S/R for one side when its Auto S/R toggle is on.
// Start is forced to 0 (trade starts at market) per the Auto S/R design.
// If no swing is found within the lookback, the existing Target is left as-is.
void ApplyAutoSRSide(bool isBuy)
{
   if(isBuy)
   {
      if(!bAutoSR) return;
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double r=FindSwingResistanceAbove(bid);
      bStart=0;
      if(r>0) bTarget=NormalizeDouble(r,_Digits);
   }
   else
   {
      if(!sAutoSR) return;
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double s=FindSwingSupportBelow(ask);
      sStart=0;
      if(s>0) sTarget=NormalizeDouble(s,_Digits);
   }
   RefreshInputs();
   SaveState();
}

bool SubmitMainLot(int dir)
{
   double lot=ObjNum(dir==1?"UI_B_MAIN_LOT":"UI_S_MAIN_LOT");
   if(lot<=0) lot=0.01;
   lot=NormalizeLot(lot);
   if(lot<minLot||lot>maxLot){ SetError("Main Lot outside broker limits."); return false; }
   if(dir==1) bLot1=lot;
   else       sLot1=lot;
   RefreshInputs();
   SaveState();
   gLastErrorText=(dir==1?"BUY":"SELL")+" Main Lot updated: "+Dbl(lot,2);
   return true;
}

//==========================================================================
//  POSITION RECONCILE
//==========================================================================
void ReconcilePositions()
{
   bTicket1=0;sTicket1=0;
   for(int i=0;i<bGapCount;i++) bTicket[i]=0;
   for(int i=0;i<sGapCount;i++) sTicket[i]=0;

   for(int p=PositionsTotal()-1;p>=0;p--)
   {
      ulong t=PositionGetTicket(p);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long magic=PositionGetInteger(POSITION_MAGIC);
      string cmt=PositionGetString(POSITION_COMMENT);
      if(magic==currBuyM&&cmt=="P1"){ bTicket1=t;bEntry1=PositionGetDouble(POSITION_PRICE_OPEN); }
      if(magic==currSellM&&cmt=="P1"){ sTicket1=t;sEntry1=PositionGetDouble(POSITION_PRICE_OPEN); }
      for(int i=0;i<bGapCount;i++)
      {
         string tag="P"+(string)(i+2);
         if(magic==currBuyM&&cmt==tag){ bTicket[i]=t;bEntry[i]=PositionGetDouble(POSITION_PRICE_OPEN); }
      }
      for(int i=0;i<sGapCount;i++)
      {
         string tag="P"+(string)(i+2);
         if(magic==currSellM&&cmt==tag){ sTicket[i]=t;sEntry[i]=PositionGetDouble(POSITION_PRICE_OPEN); }
      }
   }
}

//==========================================================================
//  BUY / SELL LOGIC
//==========================================================================
void CloseAllBuyPositions()
{
   DeleteEAOrders(1);
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)&&PositionGetString(POSITION_SYMBOL)==_Symbol&&IsBuyEngineMagic(PositionGetInteger(POSITION_MAGIC)))
         ClosePosition(t);
   }
}

void CloseAllSellPositions()
{
   DeleteEAOrders(-1);
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t)&&PositionGetString(POSITION_SYMBOL)==_Symbol&&IsSellEngineMagic(PositionGetInteger(POSITION_MAGIC)))
         ClosePosition(t);
   }
}

bool IsAbsoluteGapPrice(double value)
{
   return (InpAbsoluteGapPriceLevel>0&&value>=InpAbsoluteGapPriceLevel);
}

double Gap2StartTolerance()
{
   double spread=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*_Point;
   double configured=MathMax(0,InpGap2StartMatchPoints)*_Point;
   return MathMax(configured,spread*2.0);
}

void ArmBuyGap(int index,double returnTarget,double armedPrice,datetime now)
{
   if(index<0||index>=bGapCount) return;
   bActive[index]=true;
   bReturnTarget[index]=NormalizeDouble(returnTarget,_Digits);
   bArmedPrice[index]=NormalizeDouble(armedPrice,_Digits);
   if(index==0) bGap2PullbackStart=now;
   SaveState();
}

void ArmSellGap(int index,double returnTarget,double armedPrice,datetime now)
{
   if(index<0||index>=sGapCount) return;
   sActive[index]=true;
   sReturnTarget[index]=NormalizeDouble(returnTarget,_Digits);
   sArmedPrice[index]=NormalizeDouble(armedPrice,_Digits);
   if(index==0) sGap2PullbackStart=now;
   SaveState();
}

void TryArmBuyGap(int index,double lastStuck,double ask,datetime now)
{
   if(index<0||index>=bGapCount||bActive[index]||bTicket[index]>0) return;
   double value=bGap[index];
   if(index==0)
   {
      if(value<=0)
      {
         ArmBuyGap(index,ask,ask,now);
         return;
      }
      if(IsAbsoluteGapPrice(value))
      {
         double level=NormalizeDouble(value,_Digits);
         double tol=Gap2StartTolerance();
         if(ask<=level||MathAbs(ask-level)<=tol) ArmBuyGap(index,level,ask,now);
         return;
      }
   }
   if(lastStuck<=0) return;
   double td=PriceGap(value);
   if(td>0&&(lastStuck-ask)>=td)
      ArmBuyGap(index,lastStuck,ask,now);
}

void TryArmSellGap(int index,double lastStuck,double bid,datetime now)
{
   if(index<0||index>=sGapCount||sActive[index]||sTicket[index]>0) return;
   double value=sGap[index];
   if(index==0)
   {
      if(value<=0)
      {
         ArmSellGap(index,bid,bid,now);
         return;
      }
      if(IsAbsoluteGapPrice(value))
      {
         double level=NormalizeDouble(value,_Digits);
         double tol=Gap2StartTolerance();
         if(bid>=level||MathAbs(bid-level)<=tol) ArmSellGap(index,level,bid,now);
         return;
      }
   }
   if(lastStuck<=0) return;
   double td=PriceGap(value);
   if(td>0&&(bid-lastStuck)>=td)
      ArmSellGap(index,lastStuck,bid,now);
}

string BuyGapEntryMode(int index,double ask,datetime now)
{
   if(index<0||index>=bGapCount||bArmedPrice[index]<=0) return "";
   if(index==0)
   {
      if(bGap2PullbackStart<=0) bGap2PullbackStart=now;
      double betterPrice=bArmedPrice[index]-(MathMax(0,InpGap2PullbackPoints)*_Point);
      bool gotBetter=(ask<=betterPrice);
      bool timedOut=(InpGap2PullbackWaitSeconds<=0||((now-bGap2PullbackStart)>=InpGap2PullbackWaitSeconds));
      if(gotBetter) return "LOWER";
      if(timedOut) return "TIMEOUT";
      return "";
   }
   double gapDist=PriceGap(bGap[index]);
   if(bReturnTarget[index]>0&&ask>=bReturnTarget[index]) return "PULLBACK";
   if(gapDist>0&&MathAbs(ask-bArmedPrice[index])<=(_Point*3)) return "SAME";
   if(gapDist>0&&ask<bArmedPrice[index]) return "LOWER";
   return "";
}

string SellGapEntryMode(int index,double bid,datetime now)
{
   if(index<0||index>=sGapCount||sArmedPrice[index]<=0) return "";
   if(index==0)
   {
      if(sGap2PullbackStart<=0) sGap2PullbackStart=now;
      double betterPrice=sArmedPrice[index]+(MathMax(0,InpGap2PullbackPoints)*_Point);
      bool gotBetter=(bid>=betterPrice);
      bool timedOut=(InpGap2PullbackWaitSeconds<=0||((now-sGap2PullbackStart)>=InpGap2PullbackWaitSeconds));
      if(gotBetter) return "HIGHER";
      if(timedOut) return "TIMEOUT";
      return "";
   }
   double gapDist=PriceGap(sGap[index]);
   if(sReturnTarget[index]>0&&bid<=sReturnTarget[index]) return "PULLBACK";
   if(gapDist>0&&MathAbs(bid-sArmedPrice[index])<=(_Point*3)) return "SAME";
   if(gapDist>0&&bid>sArmedPrice[index]) return "HIGHER";
   return "";
}

bool OpenMainScalpNow(int dir,double ask,double bid)
{
   if(dir==1)
   {
      ulong t=ExecuteBuy(bLot1,"P1");
      if(t>0)
      {
         bTicket1=t;bEntry1=ask;bScalp1++;
         bScalpPullbackActive=false;bScalpPullbackStart=0;bScalpPullbackRef=0;
         bStairStage=0;
         if(InpStaircaseEnabled) ModifyPositionSLTP(t,0,StaircasePrice(true,ask,InpStairP1TPPct,true));
         SaveState();
         return true;
      }
      return false;
   }

   ulong t=ExecuteSell(sLot1,"P1");
   if(t>0)
   {
      sTicket1=t;sEntry1=bid;sScalp1++;
      sScalpPullbackActive=false;sScalpPullbackStart=0;sScalpPullbackRef=0;
      sStairStage=0;
      if(InpStaircaseEnabled) ModifyPositionSLTP(t,0,StaircasePrice(false,bid,InpStairP1TPPct,true));
      SaveState();
      return true;
   }
   return false;
}

bool TryScalpPullbackEntry(int dir,double ask,double bid,datetime now)
{
   bool isBuy=(dir==1);
   if(isBuy)
   {
      if(!bScalpPullbackActive||InpScalpPullbackWaitSeconds<=0)
         return OpenMainScalpNow(dir,ask,bid);

      double betterPrice=bScalpPullbackRef-(MathMax(0,InpScalpPullbackPoints)*_Point);
      bool gotBetter=(ask<=betterPrice);
      bool timedOut=((now-bScalpPullbackStart)>=InpScalpPullbackWaitSeconds);
      if(!gotBetter&&!timedOut)
      {
         gLastErrorText="BUY scalp waiting pullback after locked SL.";
         return false;
      }
      return OpenMainScalpNow(dir,ask,bid);
   }

   if(!sScalpPullbackActive||InpScalpPullbackWaitSeconds<=0)
      return OpenMainScalpNow(dir,ask,bid);

   double betterPrice=sScalpPullbackRef+(MathMax(0,InpScalpPullbackPoints)*_Point);
   bool gotBetter=(bid>=betterPrice);
   bool timedOut=((now-sScalpPullbackStart)>=InpScalpPullbackWaitSeconds);
   if(!gotBetter&&!timedOut)
   {
      gLastErrorText="SELL scalp waiting pullback after locked SL.";
      return false;
   }
   return OpenMainScalpNow(dir,ask,bid);
}

double ProSStartLevel(bool isBuy,double startValue,double currentPrice)
{
   if(currentPrice<=0) return 0;
   if(startValue==0) return NormalizeDouble(currentPrice,_Digits);
   if(MathAbs(startValue)>=InpAbsoluteGapPriceLevel)
      return NormalizeDouble(MathAbs(startValue),_Digits);
   return NormalizeDouble(currentPrice+startValue,_Digits);
}

void ResetProSStart(bool isBuy,int index)
{
   if(isBuy)
   {
      if(index<0||index>=bGapCount) return;
      bActive[index]=false;bArmedPrice[index]=0;bReturnTarget[index]=0;
   }
   else
   {
      if(index<0||index>=sGapCount) return;
      sActive[index]=false;sArmedPrice[index]=0;sReturnTarget[index]=0;
   }
}

bool ProSStartReady(bool isBuy,int index,double currentPrice)
{
   if(currentPrice<=0) return false;
   if(isBuy)
   {
      if(index<0||index>=bGapCount) return false;
      if(bActive[index]) return true;
      if(bArmedPrice[index]<=0)
      {
         bArmedPrice[index]=ProSStartLevel(true,bGap[index],currentPrice);
         bReturnTarget[index]=(bArmedPrice[index]>currentPrice+_Point)?1.0:((bArmedPrice[index]<currentPrice-_Point)?-1.0:0.0);
         SaveState();
      }
      bool reached=(bReturnTarget[index]==0.0)||
                   (bReturnTarget[index]>0.0&&currentPrice>=bArmedPrice[index])||
                   (bReturnTarget[index]<0.0&&currentPrice<=bArmedPrice[index]);
      if(reached){ bActive[index]=true;SaveState();return true; }
      gLastErrorText="BUY ProS waiting start "+CompactPrice(bArmedPrice[index]);
      return false;
   }

   if(index<0||index>=sGapCount) return false;
   if(sActive[index]) return true;
   if(sArmedPrice[index]<=0)
   {
      sArmedPrice[index]=ProSStartLevel(false,sGap[index],currentPrice);
      sReturnTarget[index]=(sArmedPrice[index]>currentPrice+_Point)?1.0:((sArmedPrice[index]<currentPrice-_Point)?-1.0:0.0);
      SaveState();
   }
   bool reached=(sReturnTarget[index]==0.0)||
                (sReturnTarget[index]>0.0&&currentPrice>=sArmedPrice[index])||
                (sReturnTarget[index]<0.0&&currentPrice<=sArmedPrice[index]);
   if(reached){ sActive[index]=true;SaveState();return true; }
   gLastErrorText="SELL ProS waiting start "+CompactPrice(sArmedPrice[index]);
   return false;
}

bool HasLevelPosition(bool isBuy,int level)
{
   string tag="P"+(string)level;
   long magic=isBuy?currBuyM:currSellM;
   ENUM_POSITION_TYPE type=isBuy?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
   for(int p=PositionsTotal()-1;p>=0;p--)
   {
      ulong t=PositionGetTicket(p);if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=magic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=type) continue;
      if(PositionGetString(POSITION_COMMENT)==tag) return true;
   }
   return false;
}

void ManageBuyProS(int index,double ask,double bid,datetime now)
{
   if(index<0||index>=bGapCount) return;
   if(bTicket[index]>0&&PositionSelectByTicket(bTicket[index]))
   {
      if(InpStaircaseEnabled&&(index==0||index==1))
      {
         ApplyStaircaseLevel(true,index);
         return;
      }
      double profit=PositionGetDouble(POSITION_PROFIT);
      if(bLock[index]>0&&profit>=bLock[index])
      {
         if(ClosePosition(bTicket[index]))
         {
            bTicket[index]=0;bEntry[index]=0;bLastClose[index]=now;bScalps[index]++;
            SaveState();
         }
      }
      return;
   }
   bTicket[index]=0;
   if(!bGapOn[index]) return;
   if(!ProSStartReady(true,index,ask)) return;
   if(HasLevelPosition(true,index+2)) return;
   if((now-bLastClose[index])<MAX_REOPEN_DELAY) return;
   ulong t=ExecuteBuy(bLot[index],"P"+(string)(index+2));
   if(t>0)
   {
      bTicket[index]=t;bEntry[index]=ask;
      SaveState();
   }
}

void ManageSellProS(int index,double ask,double bid,datetime now)
{
   if(index<0||index>=sGapCount) return;
   if(sTicket[index]>0&&PositionSelectByTicket(sTicket[index]))
   {
      if(InpStaircaseEnabled&&(index==0||index==1))
      {
         ApplyStaircaseLevel(false,index);
         return;
      }
      double profit=PositionGetDouble(POSITION_PROFIT);
      if(sLock[index]>0&&profit>=sLock[index])
      {
         if(ClosePosition(sTicket[index]))
         {
            sTicket[index]=0;sEntry[index]=0;sLastClose[index]=now;sScalps[index]++;
            SaveState();
         }
      }
      return;
   }
   sTicket[index]=0;
   if(!sGapOn[index]) return;
   if(!ProSStartReady(false,index,bid)) return;
   if(HasLevelPosition(false,index+2)) return;
   if((now-sLastClose[index])<MAX_REOPEN_DELAY) return;
   ulong t=ExecuteSell(sLot[index],"P"+(string)(index+2));
   if(t>0)
   {
      sTicket[index]=t;sEntry[index]=bid;
      SaveState();
   }
}

void ManageBuyLevel(int level,double ask,double bid,datetime now)
{
   if(level==1)
   {
      bool hasMain=false;
      for(int p=PositionsTotal()-1;p>=0;p--)
      {
         ulong t=PositionGetTicket(p);if(!PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=currBuyM) continue;
         if(PositionGetString(POSITION_COMMENT)!="P1") continue;
         hasMain=true;
         double open=PositionGetDouble(POSITION_PRICE_OPEN);
         if(bEntry1<=0) bEntry1=open;
         if(bGapCount>0&&bStuck1==0&&bGap[0]>0&&!IsAbsoluteGapPrice(bGap[0]))
         {
            double ng=PriceGap(bGap[0]);
            if(ng>0&&ask<=bEntry1-ng){ bStuck1=bEntry1; SaveState(); }
         }
         TryProtectPosition(t,bProtectMoney,bLockMoney);
      }
      if(!hasMain) TryScalpPullbackEntry(1,ask,bid,now);
      return;
   }

   int i=level-2;
   if(i<0||i>=bGapCount) return;
   if(IsProSIndex(i)){ ManageBuyProS(i,ask,bid,now);return; }
   if(bTicket[i]>0&&PositionSelectByTicket(bTicket[i]))
   {
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      if(bEntry[i]<=0) bEntry[i]=open;
      if(i+1<bGapCount&&bStuck[i]==0)
      {
         double ng=PriceGap(bGap[i+1]);
         if(ng>0&&ask<=bEntry[i]-ng){ bStuck[i]=bEntry[i];SaveState(); }
      }
      if(InpStaircaseEnabled&&(i==0||i==1))
      {
         ApplyStaircaseLevel(true,i);
         return;
      }
      bool reachedUpper=(bReturnTarget[i]>0&&bid>=bReturnTarget[i]);
      bool wasSafe=PositionHasSafeSL(bTicket[i]);
      if(reachedUpper)
      {
         if(TryProtectPosition(bTicket[i],0.0,bLock[i]))
         {
            bActive[i]=false;
            if(i==0) bGap2PullbackStart=0;
            if(!wasSafe) bScalps[i]++;
            SaveState();
         }
         return;
      }
      if(TryProtectPosition(bTicket[i],bTP[i],bLock[i]))
      {
         if(!wasSafe) bScalps[i]++;
         SaveState();
      }
   }
   else bTicket[i]=0;

   if(!bActive[i]||bTicket[i]>0) return;
   string entryMode=BuyGapEntryMode(i,ask,now);
   if(entryMode!=""&&(now-bLastClose[i])>=MAX_REOPEN_DELAY)
   {
      ulong t=ExecuteBuy(bLot[i],"P"+(string)level);
      if(t>0)
      {
         bTicket[i]=t;bEntry[i]=ask;
         if(i==0) bGap2PullbackStart=0;
         SaveState();
      }
   }
}

void ManageSellLevel(int level,double ask,double bid,datetime now)
{
   if(level==1)
   {
      bool hasMain=false;
      for(int p=PositionsTotal()-1;p>=0;p--)
      {
         ulong t=PositionGetTicket(p);if(!PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=currSellM) continue;
         if(PositionGetString(POSITION_COMMENT)!="P1") continue;
         hasMain=true;
         double open=PositionGetDouble(POSITION_PRICE_OPEN);
         if(sEntry1<=0) sEntry1=open;
         if(sGapCount>0&&sStuck1==0&&sGap[0]>0&&!IsAbsoluteGapPrice(sGap[0]))
         {
            double ng=PriceGap(sGap[0]);
            if(ng>0&&bid>=sEntry1+ng){ sStuck1=sEntry1; SaveState(); }
         }
         TryProtectPosition(t,sProtectMoney,sLockMoney);
      }
      if(!hasMain) TryScalpPullbackEntry(-1,ask,bid,now);
      return;
   }

   int i=level-2;
   if(i<0||i>=sGapCount) return;
   if(IsProSIndex(i)){ ManageSellProS(i,ask,bid,now);return; }
   if(sTicket[i]>0&&PositionSelectByTicket(sTicket[i]))
   {
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      if(sEntry[i]<=0) sEntry[i]=open;
      if(i+1<sGapCount&&sStuck[i]==0)
      {
         double ng=PriceGap(sGap[i+1]);
         if(ng>0&&bid>=sEntry[i]+ng){ sStuck[i]=sEntry[i];SaveState(); }
      }
      if(InpStaircaseEnabled&&(i==0||i==1))
      {
         ApplyStaircaseLevel(false,i);
         return;
      }
      bool reachedLower=(sReturnTarget[i]>0&&ask<=sReturnTarget[i]);
      bool wasSafe=PositionHasSafeSL(sTicket[i]);
      if(reachedLower)
      {
         if(TryProtectPosition(sTicket[i],0.0,sLock[i]))
         {
            sActive[i]=false;
            if(i==0) sGap2PullbackStart=0;
            if(!wasSafe) sScalps[i]++;
            SaveState();
         }
         return;
      }
      if(TryProtectPosition(sTicket[i],sTP[i],sLock[i]))
      {
         if(!wasSafe) sScalps[i]++;
         SaveState();
      }
   }
   else sTicket[i]=0;

   if(!sActive[i]||sTicket[i]>0) return;
   string entryMode=SellGapEntryMode(i,bid,now);
   if(entryMode!=""&&(now-sLastClose[i])>=MAX_REOPEN_DELAY)
   {
      ulong t=ExecuteSell(sLot[i],"P"+(string)level);
      if(t>0)
      {
         sTicket[i]=t;sEntry[i]=bid;
         if(i==0) sGap2PullbackStart=0;
         SaveState();
      }
   }
}

void ManageBuy(double ask,double bid)
{
   datetime now=TimeCurrent();
   if(!bStartReached)
   {
      if(bStart<=0){ bStartReached=true;SaveState(); }
      else
      {
         double px=NormalizeDouble(ask,_Digits),st=NormalizeDouble(bStart,_Digits);
         if((bStartAbove&&px>=st)||(!bStartAbove&&px<=st)){ bStartReached=true;SaveState(); }
         else return;
      }
   }

   if(bTarget>0&&bid>=bTarget)
   {
      CloseAllBuyPositions();
      gLastErrorText="BUY target price reached. All BUY EA positions closed.";
      if(bRepeat)
      {
         currBuyM++;ResetBuyRunState();
         double d=MathAbs(bTarget-bStart);bStart=bid;bTarget=bStart+d;bStartReached=true;RefreshInputs();
      }
      else{ bOn=false;ResetBuyRunState(); }
      SaveState();return;
   }

   ManageBuyLevel(1,ask,bid,now);
   for(int i=0;i<bGapCount;i++)
   {
      if(!bGapOn[i]&&bTicket[i]==0) continue;
      if(IsProSIndex(i)){ ManageBuyLevel(i+2,ask,bid,now);continue; }
      if(bGapOn[i])
      {
         double lastStuck=(i==0)?bStuck1:bStuck[i-1];
         TryArmBuyGap(i,lastStuck,ask,now);
      }
      ManageBuyLevel(i+2,ask,bid,now);
   }
}

void ManageSell(double ask,double bid)
{
   datetime now=TimeCurrent();
   if(!sStartReached)
   {
      if(sStart<=0){ sStartReached=true;SaveState(); }
      else
      {
         double px=NormalizeDouble(bid,_Digits),st=NormalizeDouble(sStart,_Digits);
         if((sStartAbove&&px>=st)||(!sStartAbove&&px<=st)){ sStartReached=true;SaveState(); }
         else return;
      }
   }

   if(sTarget>0&&ask<=sTarget)
   {
      CloseAllSellPositions();
      gLastErrorText="SELL target price reached. All SELL EA positions closed.";
      if(sRepeat)
      {
         currSellM++;ResetSellRunState();
         double d=MathAbs(sStart-sTarget);sStart=ask;sTarget=sStart-d;sStartReached=true;RefreshInputs();
      }
      else{ sOn=false;ResetSellRunState(); }
      SaveState();return;
   }

   ManageSellLevel(1,ask,bid,now);
   for(int i=0;i<sGapCount;i++)
   {
      if(!sGapOn[i]&&sTicket[i]==0) continue;
      if(IsProSIndex(i)){ ManageSellLevel(i+2,ask,bid,now);continue; }
      if(sGapOn[i])
      {
         double lastStuck=(i==0)?sStuck1:sStuck[i-1];
         TryArmSellGap(i,lastStuck,bid,now);
      }
      ManageSellLevel(i+2,ask,bid,now);
   }
}

//==========================================================================
//  DASHBOARD HELPERS
//==========================================================================
int UnitsFromLots(double lots){ return lots<=0?0:(int)MathRound(lots/0.01); }

void CountOpenPositions(double &bP,double &sP,int &bPos,int &sPos,int &bU,int &sU)
{
   bP=0;sP=0;bPos=0;sPos=0;bU=0;sU=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long magic=PositionGetInteger(POSITION_MAGIC);
      double profit=PositionGetDouble(POSITION_PROFIT),volume=PositionGetDouble(POSITION_VOLUME);
      if(magic==currBuyM){ bP+=profit;bPos++;bU+=UnitsFromLots(volume); }
      if(magic==currSellM){ sP+=profit;sPos++;sU+=UnitsFromLots(volume); }
   }
}

int CountSymbolSideUnits(bool buySide)
{
   int units=0;
   ENUM_POSITION_TYPE side=buySide?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=side) continue;
      units+=UnitsFromLots(PositionGetDouble(POSITION_VOLUME));
   }
   return units;
}

double DailyClosedPL()
{
   MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);dt.hour=0;dt.min=0;dt.sec=0;
   datetime ds=StructToTime(dt);double total=0;
   if(!HistorySelect(ds,TimeCurrent())) return 0;
   int n=HistoryDealsTotal();
   for(int i=0;i<n;i++)
   {
      ulong deal=HistoryDealGetTicket(i);if(deal==0) continue;
      if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      total+=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_COMMISSION);
   }
   return total;
}

//==========================================================================
//  UI HELPERS
//==========================================================================
void ObjRect(string name,int x,int y,int w,int h,color bg)
{
   ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
}

void ObjLabel(string name,int x,int y,string text,color clr,int size=8,string font="Arial")
{
   ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetString(0,name,OBJPROP_TEXT,text);ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,size);ObjectSetString(0,name,OBJPROP_FONT,font);
}

void ObjEdit(string name,int x,int y,int w,int h,color bg)
{
   ObjectCreate(0,name,OBJ_EDIT,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,C'90,110,130');
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,8);ObjectSetString(0,name,OBJPROP_FONT,"Arial");
}

void ObjButton(string name,int x,int y,int w,int h,string text,int size=8,string tooltip="")
{
   ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetString(0,name,OBJPROP_TEXT,text);ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,size);ObjectSetString(0,name,OBJPROP_FONT,"Arial Bold");
   if(tooltip!="") ObjectSetString(0,name,OBJPROP_TOOLTIP,tooltip);
}

void SetButton(string name,bool active,color onBg,color offBg,string text="")
{
   if(ObjectFind(0,name)<0) return;
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,active?onBg:offBg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,active?clrWhite:C'190,190,190');
   if(text!="") ObjectSetString(0,name,OBJPROP_TEXT,text);
}

void SetButtonColor(string name,color bg,color fg,string text="")
{
   if(ObjectFind(0,name)<0) return;
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,fg);
   if(text!="") ObjectSetString(0,name,OBJPROP_TEXT,text);
}

void StyleMinButton()
{
   if(uiCollapsed)
      SetButtonColor("UI_MIN",C'40,170,75',clrWhite,"+");
   else
      SetButtonColor("UI_MIN",C'45,160,255',clrWhite,"-");
}

void ShowObject(string name,bool show)
{
   if(ObjectFind(0,name)>=0)
      ObjectSetInteger(0,name,OBJPROP_TIMEFRAMES,show?OBJ_ALL_PERIODS:OBJ_NO_PERIODS);
}

void SetUIPanelVisible(bool show)
{
   int total=ObjectsTotal(0);
   for(int i=total-1;i>=0;i--)
   {
      string name=ObjectName(0,i);
      if(StringFind(name,"UI_")!=0) continue;
      if(StringFind(name,"UI_OSP_")==0) continue;
      if(name=="UI_MIN") continue;
      ShowObject(name,show);
   }
   ObjectSetString(0,"UI_MIN",OBJPROP_TEXT,show?"-":"+");
   StyleMinButton();
}

void OSPSetVisible(bool show)
{
   int total=ObjectsTotal(0);
   for(int i=total-1;i>=0;i--)
   {
      string name=ObjectName(0,i);
      if(StringFind(name,"UI_OSP_")==0) ShowObject(name,show);
   }
}

bool OSPSync()
{
   ospTarget=StringToDouble(ObjectGetString(0,OSPName("TARGET"),OBJPROP_TEXT));
   ospQty=StringToDouble(ObjectGetString(0,OSPName("QTY"),OBJPROP_TEXT));
   ospWidth=StringToDouble(ObjectGetString(0,OSPName("WIDTH"),OBJPROP_TEXT));
   ospSL=StringToDouble(ObjectGetString(0,OSPName("SL"),OBJPROP_TEXT));
   ospMaxBuy=(int)StringToInteger(ObjectGetString(0,OSPName("MAXBUY"),OBJPROP_TEXT));
   ospMaxSell=(int)StringToInteger(ObjectGetString(0,OSPName("MAXSELL"),OBJPROP_TEXT));
   if(ospTarget<=0||ospQty<=0||ospWidth<=0||ospSL<0){ospStatus="Target, lot, and width must be above zero; SL may be zero.";return false;}
   if(ospMaxBuy<-1||ospMaxSell<-1){ospStatus="Maximum sides must be -1 or higher.";return false;}
   ospStatus="Settings synced for new orders.";return true;
}

void OSPBuildPanel(int x,int y,int width)
{
   int fieldX=x+72,fieldW=58,fieldX2=x+262;
   ObjRect(OSPName("PANEL"),x,y,width,196,C'20,24,32');
   ObjRect(OSPName("HDR"),x,y,width,28,C'56,70,94');
   ObjLabel(OSPName("TITLE"),x+10,y+7,"OPPOSITE PENDING ENGINE",clrWhite,10,"Arial Bold");
   ObjLabel(OSPName("INFO"),x+230,y+8,"Closed-candle limit orders",C'190,205,225',8,"Arial");
   ObjButton(OSPName("MA"),x+10,y+38,42,20,"MA",7,"Moving-average strategy ON/OFF");
   ObjButton(OSPName("RISK"),x+56,y+38,42,20,"RISK",7,"Risk strategy ON/OFF");
   ObjButton(OSPName("SMC"),x+102,y+38,42,20,"SMC",7,"Smart-money sweep strategy ON/OFF");
   ObjButton(OSPName("NEWS"),x+150,y+38,62,20,"NEWS",7,"High-impact news guard ON/OFF");
   ObjButton(OSPName("VOLA"),x+216,y+38,62,20,"VOLA",7,"High-volatility guard ON/OFF");
   ObjButton(OSPName("BUY"),x+288,y+38,42,20,"BUY",7,"Trade buy limits only");
   ObjButton(OSPName("SELL"),x+334,y+38,42,20,"SELL",7,"Trade sell limits only");
   ObjButton(OSPName("BOTH"),x+380,y+38,46,20,"BOTH",7,"Trade both sides");
   ObjLabel(OSPName("L_TARGET"),x+10,y+70,"Target $",C'190,205,225',8);ObjEdit(OSPName("TARGET"),fieldX,y+66,fieldW,20,C'34,41,54');
   ObjLabel(OSPName("L_QTY"),x+144,y+70,"Lot",C'190,205,225',8);ObjEdit(OSPName("QTY"),x+172,y+66,fieldW,20,C'34,41,54');
   ObjLabel(OSPName("L_WIDTH"),x+240,y+70,"Width",C'190,205,225',8);ObjEdit(OSPName("WIDTH"),x+282,y+66,fieldW,20,C'34,41,54');
   ObjLabel(OSPName("L_SL"),x+350,y+70,"SL",C'190,205,225',8);ObjEdit(OSPName("SL"),x+370,y+66,fieldW,20,C'34,41,54');
   ObjLabel(OSPName("L_MAXBUY"),x+10,y+98,"Max Buy",C'190,205,225',8);ObjEdit(OSPName("MAXBUY"),fieldX,y+94,fieldW,20,C'34,41,54');
   ObjLabel(OSPName("L_MAXSELL"),x+144,y+98,"Max Sell",C'190,205,225',8);ObjEdit(OSPName("MAXSELL"),x+192,y+94,fieldW,20,C'34,41,54');
   ObjButton(OSPName("SYNC"),x+10,y+122,46,22,BTN_SYNC_TEXT,11,"Apply settings to new pending orders");
   ObjButton(OSPName("START"),x+62,y+122,46,22,BTN_START_TEXT,11,"Start or stop this engine");
   ObjButton(OSPName("PAUSE"),x+114,y+122,46,22,BTN_PAUSE_TEXT,11,"Pause or resume new orders");
   ObjButton(OSPName("CLOSE"),x+166,y+122,72,22,"CLOSE",7,"Close this engine's pending and active orders");
   ObjLabel(OSPName("STATE"),x+250,y+127,"",C'130,255,185',8,"Arial Bold");
   ObjLabel(OSPName("STATUS"),x+10,y+154,"",C'210,220,230',8,"Arial");
   ObjLabel(OSPName("WAIT"),x+10,y+174,"Runs when a candle closes. Existing pending orders refresh each candle.",C'140,160,180',7,"Arial");
}

void OSPRefreshPanel()
{
   SetButton(OSPName("MA"),ospMAEnabled,C'50,110,205',C'75,75,75',"MA");
   SetButton(OSPName("RISK"),ospRiskEnabled,C'215,130,35',C'75,75,75',"RISK");
   SetButton(OSPName("SMC"),ospSMCEnabled,C'135,90,190',C'75,75,75',"SMC");
   SetButton(OSPName("NEWS"),ospNewsGuard,C'185,70,70',C'75,75,75',"NEWS");
   SetButton(OSPName("VOLA"),ospVolatilityGuard,C'205,130,30',C'75,75,75',"VOLA");
   SetButton(OSPName("BUY"),ospMode==0,C'45,140,95',C'75,75,75',"BUY");
   SetButton(OSPName("SELL"),ospMode==1,C'190,80,80',C'75,75,75',"SELL");
   SetButton(OSPName("BOTH"),ospMode==2,C'55,115,205',C'75,75,75',"BOTH");
   SetButton(OSPName("START"),ospRunning,C'210,90,45',C'45,145,95',ospRunning?BTN_STOP_TEXT:BTN_START_TEXT);
   SetButton(OSPName("PAUSE"),ospPaused,C'220,145,30',C'75,75,75',ospPaused?BTN_START_TEXT:BTN_PAUSE_TEXT);
   SetObjText(OSPName("STATE"),ospRunning?(ospPaused?"PAUSED":"LIVE"):"IDLE");
   SetObjText(OSPName("STATUS"),"NOW: "+ospStatus+" | VOLA: "+OSPVolatility());
   SetButton("UI_B_OSP_EXP",ospExpanded,C'45,160,255',C'75,75,75',ospExpanded?"-":"+");
   SetButton("UI_S_OSP_EXP",ospExpanded,C'45,160,255',C'75,75,75',ospExpanded?"-":"+");
}

void CaptureVisibleInputs()
{
   if(ObjectFind(0,"UI_B_START_PRICE")>=0) SyncBuy();
   if(ObjectFind(0,"UI_S_START_PRICE")>=0) SyncSell();
   SyncControlInputs();
}

void CreateInterface()
{
   ObjectsDeleteAll(0,"UI_");
   int sw=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
   int panelW=370,panelGap=15,totalW=(panelW*2)+panelGap;
   int dashPad=8,dashBoxW=panelW-16,dashH=128,dashBoxH=84;
   int x=(sw/2)-(totalW/2);if(x<5)x=5;
   int y=30;
   ObjButton("UI_MIN",x,y-26,32,22,uiCollapsed?"+":"-",10);
   StyleMinButton();

   int panelH=211+(MathMax(bGapCount,sGapCount)*25);
   ObjRect("UI_PNLB",x,y,panelW,panelH,C'18,28,44');ObjRect("UI_HDRB",x,y,panelW,28,C'36,89,160');
   ObjLabel("UI_HB",x+10,y+7,"BUY - "+g_AccountName,clrWhite,10,"Arial Bold");
   int lx=x+10,by=y+38;
   ObjButton("UI_B_START",lx,by,40,24,BTN_START_TEXT,11,"Start BUY");
   ObjButton("UI_B_PAUSE",lx+44,by,40,24,BTN_PAUSE_TEXT,11,"Pause or resume BUY");
   ObjButton("UI_B_CLOSE",lx+88,by,40,24,BTN_STOP_TEXT,10,"Stop BUY and close BUY trades");
   ObjButton("UI_B_SYNC",lx+132,by,40,24,BTN_SYNC_TEXT,12,"Sync BUY settings");
   ObjButton("UI_B_REPEAT",lx+176,by,48,24,"REP",7,"Repeat BUY after target");
   by+=32;
   ObjLabel("UI_B_MAINLOT_L",lx,by+4,"Lot",C'180,210,255',7,"Arial Bold");
   ObjEdit("UI_B_MAIN_LOT",lx+24,by,45,20,C'29,41,58');
   ObjLabel("UI_B_PROT_L",lx+80,by+4,"Prot",C'180,210,255',7,"Arial Bold");
   ObjEdit("UI_B_PROTECT",lx+116,by,45,20,C'29,41,58');
   ObjLabel("UI_B_LOCK_L",lx+170,by+4,"Lock",C'145,230,145',7,"Arial Bold");
   ObjEdit("UI_B_LOCK",lx+204,by,45,20,C'29,41,58');
   ObjButton("UI_B_OPP_ON",lx+254,by-1,42,22,"B+S",7,"BUY plus SELL helper ON/OFF");
   ObjButton("UI_B_OSP_EXP",lx+300,by-1,20,22,"+",10,"Show or hide Opposite Pending Engine");
   ObjEdit("UI_B_OPP_MONEY",lx+324,by,27,20,C'29,41,58');
   by+=25;
   ObjButton("UI_B_BASKET_ON",lx+22,by-1,82,22,"BASK: OFF",7,"Basket close ON/OFF");
   ObjEdit("UI_B_BASKET",lx+108,by,58,20,C'29,41,58');
   ObjButton("UI_B_RESTART",lx+172,by-1,36,22,RESTART_BTN_TEXT,12,"Restart BUY from market");
   ObjLabel("UI_BSTAT",lx+216,by+4,"",C'0,255,127',9,"Arial Bold");
   by+=29;
   ObjLabel("UI_BL0",lx,by+3,"Start",C'130,200,255');ObjEdit("UI_B_START_PRICE",lx+36,by,58,20,C'29,41,58');
   ObjLabel("UI_BL1",lx+102,by+3,"Target",C'145,230,145');ObjEdit("UI_B_TARGET_PRICE",lx+146,by,58,20,C'29,41,58');
   ObjButton("UI_B_SUBMIT_SL",lx+214,by-1,54,22,"SL OFF",7,"BUY market-price SL ON/OFF");
   ObjEdit("UI_B_SL_LOCK",lx+274,by,58,20,C'29,41,58');
   by+=25;
   ObjButton("UI_B_AUTOSR",lx,by,150,20,"AUTO S/R: OFF",7,"Auto-set Target from swing S/R on this chart's timeframe (recomputed each new bar). Start is forced to 0/market while ON.");
   by+=30;
   ObjLabel("UI_BH1",lx+36,by+3,"Gap/St",C'255,215,0',8,"Arial Bold");
   ObjLabel("UI_BH2",lx+88,by+3,"Lot",C'180,210,235',8,"Arial Bold");
   ObjLabel("UI_BH3",lx+130,by+3,"Profit/Tgt",C'145,230,145',8,"Arial Bold");
   ObjLabel("UI_BH4",lx+188,by+3,"Lock/Book",C'145,230,145',8,"Arial Bold");
   ObjLabel("UI_BH5",lx+246,by+3,"ON/OFF",C'190,190,190',8,"Arial Bold");
   for(int i=0;i<bGapCount;i++)
   {
      int level=i+2;by+=25;
      ObjLabel("UI_BG_L"+(string)i,lx,by+3,IsProSIndex(i)?"ProS":"Gap"+(string)level,C'255,215,0');
      ObjEdit("UI_B_GAP"+(string)i,lx+40,by,42,20,C'29,41,58');
      ObjEdit("UI_B_LOT"+(string)i,lx+86,by,42,20,C'29,41,58');
      ObjEdit("UI_B_PROFIT"+(string)i,lx+132,by,50,20,C'29,41,58');
      ObjEdit("UI_B_LOCK_G"+(string)i,lx+186,by,46,20,C'29,41,58');
      ObjButton("UI_B_GAPON"+(string)i,lx+242,by,58,20,"ON",8,IsProSIndex(i)?"ProS ON/OFF. Lock books profit.":"Gap ON/OFF");
   }
   by+=28;

   int sx=x+panelW+panelGap;
   ObjRect("UI_PNLS",sx,y,panelW,panelH,C'50,24,24');ObjRect("UI_HDRS",sx,y,panelW,28,C'150,52,52');
   ObjLabel("UI_HS",sx+10,y+7,"SELL - "+g_AccountName,clrWhite,10,"Arial Bold");
   int slx=sx+10,sy=y+38;
   ObjButton("UI_S_START",slx,sy,40,24,BTN_START_TEXT,11,"Start SELL");
   ObjButton("UI_S_PAUSE",slx+44,sy,40,24,BTN_PAUSE_TEXT,11,"Pause or resume SELL");
   ObjButton("UI_S_CLOSE",slx+88,sy,40,24,BTN_STOP_TEXT,10,"Stop SELL and close SELL trades");
   ObjButton("UI_S_SYNC",slx+132,sy,40,24,BTN_SYNC_TEXT,12,"Sync SELL settings");
   ObjButton("UI_S_REPEAT",slx+176,sy,48,24,"REP",7,"Repeat SELL after target");
   sy+=32;
   ObjLabel("UI_S_MAINLOT_L",slx,sy+4,"Lot",C'255,185,190',7,"Arial Bold");
   ObjEdit("UI_S_MAIN_LOT",slx+24,sy,45,20,C'48,32,36');
   ObjLabel("UI_S_PROT_L",slx+80,sy+4,"Prot",C'255,185,190',7,"Arial Bold");
   ObjEdit("UI_S_PROTECT",slx+116,sy,45,20,C'48,32,36');
   ObjLabel("UI_S_LOCK_L",slx+170,sy+4,"Lock",C'145,230,145',7,"Arial Bold");
   ObjEdit("UI_S_LOCK",slx+204,sy,45,20,C'48,32,36');
   ObjButton("UI_S_OPP_ON",slx+254,sy-1,42,22,"S+B",7,"SELL plus BUY helper ON/OFF");
   ObjButton("UI_S_OSP_EXP",slx+300,sy-1,20,22,"+",10,"Show or hide Opposite Pending Engine");
   ObjEdit("UI_S_OPP_MONEY",slx+324,sy,27,20,C'48,32,36');
   sy+=25;
   ObjButton("UI_S_BASKET_ON",slx+22,sy-1,82,22,"BASK: OFF",7,"Basket close ON/OFF");
   ObjEdit("UI_S_BASKET",slx+108,sy,58,20,C'48,32,36');
   ObjButton("UI_S_RESTART",slx+172,sy-1,36,22,RESTART_BTN_TEXT,12,"Restart SELL from market");
   ObjLabel("UI_SSTAT",slx+216,sy+4,"",C'255,80,50',9,"Arial Bold");
   sy+=29;
   ObjLabel("UI_SL0",slx,sy+3,"Start",C'255,185,190');ObjEdit("UI_S_START_PRICE",slx+36,sy,58,20,C'48,32,36');
   ObjLabel("UI_SL1",slx+102,sy+3,"Target",C'145,230,145');ObjEdit("UI_S_TARGET_PRICE",slx+146,sy,58,20,C'48,32,36');
   ObjButton("UI_S_SUBMIT_SL",slx+214,sy-1,54,22,"SL OFF",7,"SELL market-price SL ON/OFF");
   ObjEdit("UI_S_SL_LOCK",slx+274,sy,58,20,C'48,32,36');
   sy+=25;
   ObjButton("UI_S_AUTOSR",slx,sy,150,20,"AUTO S/R: OFF",7,"Auto-set Target from swing S/R on this chart's timeframe (recomputed each new bar). Start is forced to 0/market while ON.");
   sy+=30;
   ObjLabel("UI_SH1",slx+36,sy+3,"Gap/St",C'255,215,0',8,"Arial Bold");
   ObjLabel("UI_SH2",slx+88,sy+3,"Lot",C'255,185,190',8,"Arial Bold");
   ObjLabel("UI_SH3",slx+130,sy+3,"Profit/Tgt",C'145,230,145',8,"Arial Bold");
   ObjLabel("UI_SH4",slx+188,sy+3,"Lock/Book",C'145,230,145',8,"Arial Bold");
   ObjLabel("UI_SH5",slx+246,sy+3,"ON/OFF",C'190,190,190',8,"Arial Bold");
   for(int i=0;i<sGapCount;i++)
   {
      int level=i+2;sy+=25;
      ObjLabel("UI_SG_L"+(string)i,slx,sy+3,IsProSIndex(i)?"ProS":"Gap"+(string)level,C'255,215,0');
      ObjEdit("UI_S_GAP"+(string)i,slx+40,sy,42,20,C'48,32,36');
      ObjEdit("UI_S_LOT"+(string)i,slx+86,sy,42,20,C'48,32,36');
      ObjEdit("UI_S_PROFIT"+(string)i,slx+132,sy,50,20,C'48,32,36');
      ObjEdit("UI_S_LOCK_G"+(string)i,slx+186,sy,46,20,C'48,32,36');
      ObjButton("UI_S_GAPON"+(string)i,slx+242,sy,58,20,"ON",8,IsProSIndex(i)?"ProS ON/OFF. Lock books profit.":"Gap ON/OFF");
   }
   sy+=28;

   int dy=y+panelH+10;
   ObjRect("UI_DASH",x,dy,totalW,dashH,C'14,19,29');
   ObjLabel("UI_DTITLE",x+10,dy+6,"JNS SCALP V22",C'255,215,0',10,"Arial Bold");
   ObjLabel("UI_BAL",x+10,dy+23,"",C'120,205,255',8,"Arial");
   ObjLabel("UI_WARN",sx+10,dy+6,"",C'255,160,80',8,"Arial Bold");
   ObjRect("UI_DASH_BUY_BOX",x+dashPad,dy+39,dashBoxW,dashBoxH,C'10,26,36');
   ObjRect("UI_DASH_SELL_BOX",sx+dashPad,dy+39,dashBoxW,dashBoxH,C'38,18,22');
   for(int i=0;i<8;i++)
   {
      ObjLabel("UI_BIF"+(string)i,x+14,dy+44+(i*10),"",C'120,255,210',7,"Consolas");
      ObjLabel("UI_SIF"+(string)i,sx+14,dy+44+(i*10),"",C'255,190,190',7,"Consolas");
   }
   OSPBuildPanel(x,dy+dashH+8,totalW);
   RefreshInputs();
   SetUIPanelVisible(!uiCollapsed);
   OSPSetVisible(!uiCollapsed&&ospExpanded);
}

void UpdateDisplay()
{
   ReconcilePositions();
   datetime now=TimeCurrent();
   StyleMinButton();
   SetButton("UI_B_START",bOn,C'0,150,255',C'70,90,120');
   SetButton("UI_B_PAUSE",bPaused,C'255,150,20',C'80,80,80');
   SetButton("UI_B_REPEAT",bRepeat,C'40,170,75',C'80,80,80');
   SetButton("UI_S_START",sOn,C'255,80,35',C'125,60,60');
   SetButton("UI_S_PAUSE",sPaused,C'255,150,20',C'80,80,80');
   SetButton("UI_S_REPEAT",sRepeat,C'40,170,75',C'80,80,80');
   SetButtonColor("UI_B_CLOSE",now<=bCloseFlash?C'230,60,60':C'220,220,220',now<=bCloseFlash?clrWhite:clrBlack);
   SetButtonColor("UI_S_CLOSE",now<=sCloseFlash?C'230,60,60':C'220,220,220',now<=sCloseFlash?clrWhite:clrBlack);
   SetButtonColor("UI_B_SYNC",now<=bSyncFlash?C'45,160,255':C'220,220,220',now<=bSyncFlash?clrWhite:clrBlack);
   SetButtonColor("UI_S_SYNC",now<=sSyncFlash?C'45,160,255':C'220,220,220',now<=sSyncFlash?clrWhite:clrBlack);
   SetButton("UI_B_SUBMIT_SL",bStopOn,C'45,150,80',C'75,75,75',bStopOn?"SL ON":"SL OFF");
   SetButton("UI_S_SUBMIT_SL",sStopOn,C'45,150,80',C'75,75,75',sStopOn?"SL ON":"SL OFF");
   SetButton("UI_B_BASKET_ON",bBasketOn,C'45,150,80',C'75,75,75',bBasketOn?"BASK: ON":"BASK: OFF");
   SetButton("UI_S_BASKET_ON",sBasketOn,C'45,150,80',C'75,75,75',sBasketOn?"BASK: ON":"BASK: OFF");
   SetButton("UI_B_AUTOSR",bAutoSR,C'45,150,80',C'75,75,75',bAutoSR?"AUTO S/R: ON":"AUTO S/R: OFF");
   SetButton("UI_S_AUTOSR",sAutoSR,C'45,150,80',C'75,75,75',sAutoSR?"AUTO S/R: ON":"AUTO S/R: OFF");
   SetButtonColor("UI_B_RESTART",bBasketOn?(bBasketClosed?C'40,170,75':C'105,90,170'):C'45,45,45',bBasketOn?clrWhite:C'120,120,120',RESTART_BTN_TEXT);
   SetButtonColor("UI_S_RESTART",sBasketOn?(sBasketClosed?C'40,170,75':C'105,90,170'):C'45,45,45',sBasketOn?clrWhite:C'120,120,120',RESTART_BTN_TEXT);
   SetButton("UI_B_OPP_ON",bOppOn,C'35,150,210',C'75,75,75',"B+S");
   SetButton("UI_S_OPP_ON",sOppOn,C'190,80,80',C'75,75,75',"S+B");
   OSPRefreshPanel();

   for(int i=0;i<bGapCount;i++)
      SetButton("UI_B_GAPON"+(string)i,bGapOn[i],C'35,200,55',C'75,75,75',bGapOn[i]?"ON":"OFF");
   for(int i=0;i<sGapCount;i++)
      SetButton("UI_S_GAPON"+(string)i,sGapOn[i],C'35,200,55',C'75,75,75',sGapOn[i]?"ON":"OFF");

   string bs=bOn?(bPaused?"PAUSED":(bStartReached?"LIVE":"WAIT START")):"IDLE";
   string ss=sOn?(sPaused?"PAUSED":(sStartReached?"LIVE":"WAIT START")):"IDLE";
   int allBuyUnits=CountSymbolSideUnits(true);
   int allSellUnits=CountSymbolSideUnits(false);
   SetObjText("UI_HB","BUY - "+g_AccountName+" | Opened Buy = "+(string)allBuyUnits);
   SetObjText("UI_HS","SELL - "+g_AccountName+" | Opened Sell = "+(string)allSellUnits);
   SetObjText("UI_BSTAT",bs);SetObjText("UI_SSTAT",ss);

   double bProfit,sProfit;int bPos,sPos,bUnits,sUnits;
   CountOpenPositions(bProfit,sProfit,bPos,sPos,bUnits,sUnits);
   double balance=AccountInfoDouble(ACCOUNT_BALANCE),equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPL=DailyClosedPL();
   SetObjText("UI_BAL",StringFormat("Balance %.2f | Equity %.2f | Daily P/L %.2f | B Bask %+.2f/%.2f %s | S Bask %+.2f/%.2f %s",
      balance,equity,dailyPL,EABasketProfit(1),bBasketMoney,bBasketOn?"ON":"OFF",EABasketProfit(-1),sBasketMoney,sBasketOn?"ON":"OFF"));
   SetObjText("UI_WARN",gLastErrorText);

   int bTotal=bScalp1,sTotal=sScalp1;
   for(int i=0;i<bGapCount;i++) bTotal+=bScalps[i];
   for(int i=0;i<sGapCount;i++) sTotal+=sScalps[i];

   SetObjText("UI_BIF0",StringFormat("BUY  Start:%s Target:%s Lot:%s Open:%d P/L:%+.2f",
      bStart>0?CompactPrice(bStart):"MARKET",bTarget>0?CompactPrice(bTarget):"UNLIMITED",Dbl(bLot1,2),bPos,bProfit));
   SetObjText("UI_SIF0",StringFormat("SELL Start:%s Target:%s Lot:%s Open:%d P/L:%+.2f",
      sStart>0?CompactPrice(sStart):"MARKET",sTarget>0?CompactPrice(sTarget):"UNLIMITED",Dbl(sLot1,2),sPos,sProfit));
   SetObjText("UI_BIF1","Row   Lot    Profit/Tgt Book  State       P/L   Safe");
   SetObjText("UI_SIF1","Row   Lot    Profit/Tgt Book  State       P/L   Safe");
   for(int r=2;r<8;r++){ SetObjText("UI_BIF"+(string)r,"");SetObjText("UI_SIF"+(string)r,""); }
   for(int i=0;i<MathMin(bGapCount,4);i++)
   {
      string row=IsProSIndex(i)?"ProS":"G"+(string)(i+2);
      string state=!bGapOn[i]?"OFF":(bTicket[i]>0?"OPEN":(IsProSIndex(i)?(bActive[i]?"READY":"WAIT START"):(bActive[i]?"WAIT PULL":"WAIT STUCK")));
      string targetText=IsProSIndex(i)?CompactPrice(bTP[i]):Dbl(bTP[i],2);
      SetObjText("UI_BIF"+(string)(i+2),StringFormat("%-5s %-6s %-10s %-5s %-10s %+.2f %d",
         row,Dbl(bLot[i],2),targetText,Dbl(bLock[i],2),state,PositionProfit(bTicket[i]),bScalps[i]));
   }
   for(int i=0;i<MathMin(sGapCount,4);i++)
   {
      string row=IsProSIndex(i)?"ProS":"G"+(string)(i+2);
      string state=!sGapOn[i]?"OFF":(sTicket[i]>0?"OPEN":(IsProSIndex(i)?(sActive[i]?"READY":"WAIT START"):(sActive[i]?"WAIT PULL":"WAIT STUCK")));
      string targetText=IsProSIndex(i)?CompactPrice(sTP[i]):Dbl(sTP[i],2);
      SetObjText("UI_SIF"+(string)(i+2),StringFormat("%-5s %-6s %-10s %-5s %-10s %+.2f %d",
         row,Dbl(sLot[i],2),targetText,Dbl(sLock[i],2),state,PositionProfit(sTicket[i]),sScalps[i]));
   }
   SetObjText("UI_BIF6",StringFormat("P1 Lot:%s Prot:%s Lock:%s | Scalp:%d Total:%d | Bad:%d/%d",
      Dbl(bLot1,2),Dbl(bProtectMoney,2),Dbl(bLockMoney,2),bScalp1,bTotal,bBadCloses,BAD_CLOSE_LIMIT));
   SetObjText("UI_SIF6",StringFormat("P1 Lot:%s Prot:%s Lock:%s | Scalp:%d Total:%d | Bad:%d/%d",
      Dbl(sLot1,2),Dbl(sProtectMoney,2),Dbl(sLockMoney,2),sScalp1,sTotal,sBadCloses,BAD_CLOSE_LIMIT));
   SetObjText("UI_BIF7",StringFormat("Magic BUY:%I64d | SL:%s | B+S:%s %.2f",currBuyM,(bStopOn&&bStopPrice>0)?CompactPrice(bStopPrice):"OFF",bOppOn?"ON":"OFF",bOppMoney));
   SetObjText("UI_SIF7",StringFormat("Magic SELL:%I64d | SL:%s | S+B:%s %.2f",currSellM,(sStopOn&&sStopPrice>0)?CompactPrice(sStopPrice):"OFF",sOppOn?"ON":"OFF",sOppMoney));
   ChartRedraw();
}

//==========================================================================
//  EVENTS
// Testing only: replicates clicking Start on both sides plus turning Auto S/R on,
// so InpAutoStartForBacktest can drive an unattended (non-visual/optimizer) backtest
// through the full feature set: gap engine, staircase T/P, and Auto S/R Target.
// Only ever called from OnInit behind an MQL_TESTER guard - see there.
void AutoStartForBacktest()
{
   if(SyncBuy())
   {
      currBuyM++;bOn=true;bPaused=false;ResetBuyRunState();
      if(bStart<=0){ bStartReached=true;bStartAbove=false; }
      else
      {
         double cur=NormalizeDouble(SymbolInfoDouble(_Symbol,SYMBOL_ASK),_Digits);
         double st=NormalizeDouble(bStart,_Digits);
         bStartAbove=(st>cur);bStartReached=bStartAbove?(cur>=st):(cur<=st);
      }
   }
   if(SyncSell())
   {
      currSellM++;sOn=true;sPaused=false;ResetSellRunState();
      if(sStart<=0){ sStartReached=true;sStartAbove=false; }
      else
      {
         double cur=NormalizeDouble(SymbolInfoDouble(_Symbol,SYMBOL_BID),_Digits);
         double st=NormalizeDouble(sStart,_Digits);
         sStartAbove=(st>cur);sStartReached=sStartAbove?(cur>=st):(cur<=st);
      }
   }
   bAutoSR=true;sAutoSR=true;
   ApplyAutoSRSide(true);
   ApplyAutoSRSide(false);
   SaveState();
   UpdateDisplay();
   Print("InpAutoStartForBacktest: BUY on=",bOn," SELL on=",sOn," AutoSR B/S=",bAutoSR,"/",sAutoSR);
}

//==========================================================================
int OnInit()
{
   if(!CheckAuthorization()) return INIT_FAILED;
   GV_PREFIX="PST22_895252_"+_Symbol+"_";
   minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   lotStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(minLot<=0||maxLot<=0||lotStep<=0){ Alert("Invalid broker lot settings.");return INIT_FAILED; }
   ospFastHandle=iMA(_Symbol,_Period,ospFastEMA,0,MODE_EMA,PRICE_CLOSE);
   ospSlowHandle=iMA(_Symbol,_Period,ospSlowEMA,0,MODE_EMA,PRICE_CLOSE);
   ospATRHandle=iATR(_Symbol,_Period,14);
   if(ospFastHandle==INVALID_HANDLE||ospSlowHandle==INVALID_HANDLE||ospATRHandle==INVALID_HANDLE)
   {
      Alert("Could not start the Opposite Pending Engine indicators.");
      return INIT_FAILED;
   }
   RestoreState();
   SanitizeStoredGapRows();
   SaveState();
   CreateInterface();
   UpdateDisplay();
   if(InpAutoStartForBacktest&&MQLInfoInteger(MQL_TESTER)) AutoStartForBacktest();
   Print("Pro Scalper Terminal v22 ready. Auto trade removed. Account: ",g_AccountName);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   CaptureVisibleInputs();
   SaveState();
   ObjectsDeleteAll(0,"UI_");
   if(ospFastHandle!=INVALID_HANDLE) IndicatorRelease(ospFastHandle);
   if(ospSlowHandle!=INVALID_HANDLE) IndicatorRelease(ospSlowHandle);
   if(ospATRHandle!=INVALID_HANDLE) IndicatorRelease(ospATRHandle);
   ChartRedraw();
}

void OnTick()
{
   if(!CanTrade()){ UpdateDisplay();return; }
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(bAutoSR||sAutoSR)
   {
      datetime curBar=iTime(_Symbol,_Period,0);
      if(curBar!=gLastSRBarTime)
      {
         gLastSRBarTime=curBar;
         ApplyAutoSRSide(true);
         ApplyAutoSRSide(false);
      }
   }
   ReconcilePositions();
   CheckMarketStopLoss(ask,bid);
   if(bOn&&!bPaused) ManageBuy(ask,bid);
   if(sOn&&!sPaused) ManageSell(ask,bid);
   OSPManage();
   ManageOppositeScalps();
   CheckBasketClose();
   UpdateDisplay();
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_OBJECT_ENDEDIT)
   {
      if(StringFind(sparam,"UI_OSP_")==0) OSPSync();
      if(StringFind(sparam,"UI_B_")==0) SyncBuy();
      if(StringFind(sparam,"UI_S_")==0) SyncSell();
      if(sparam=="UI_B_PROTECT"||sparam=="UI_S_PROTECT"||sparam=="UI_B_LOCK"||sparam=="UI_S_LOCK"||
         sparam=="UI_B_BASKET"||sparam=="UI_S_BASKET"||sparam=="UI_B_SL_LOCK"||sparam=="UI_S_SL_LOCK"||
         sparam=="UI_B_OPP_MONEY"||sparam=="UI_S_OPP_MONEY")
         SyncControlInputs();
      UpdateDisplay();
      return;
   }
   if(id!=CHARTEVENT_OBJECT_CLICK) return;

   if(sparam=="UI_MIN")
   {
      CaptureVisibleInputs();
      uiCollapsed=!uiCollapsed;
      SetUIPanelVisible(!uiCollapsed);
      SaveState();UpdateDisplay();
      return;
   }

   if(sparam=="UI_B_OSP_EXP"||sparam=="UI_S_OSP_EXP")
   {
      CaptureVisibleInputs();
      ospExpanded=!ospExpanded;
      OSPSetVisible(!uiCollapsed&&ospExpanded);
      SaveState();ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }

   if(sparam==OSPName("MA")){ospMAEnabled=!ospMAEnabled;ospStatus=ospMAEnabled?"MA enabled.":"MA disabled.";UpdateDisplay();return;}
   if(sparam==OSPName("RISK")){ospRiskEnabled=!ospRiskEnabled;ospStatus=ospRiskEnabled?"Risk enabled.":"Risk disabled.";UpdateDisplay();return;}
   if(sparam==OSPName("SMC")){ospSMCEnabled=!ospSMCEnabled;ospStatus=ospSMCEnabled?"SMC enabled.":"SMC disabled.";UpdateDisplay();return;}
   if(sparam==OSPName("NEWS")){ospNewsGuard=!ospNewsGuard;ospStatus=ospNewsGuard?"News guard enabled.":"News guard disabled.";UpdateDisplay();return;}
   if(sparam==OSPName("VOLA")){ospVolatilityGuard=!ospVolatilityGuard;ospStatus=ospVolatilityGuard?"Volatility guard enabled.":"Volatility guard disabled.";UpdateDisplay();return;}
   if(sparam==OSPName("BUY")){ospMode=0;ospStatus="Buy limits selected.";UpdateDisplay();return;}
   if(sparam==OSPName("SELL")){ospMode=1;ospStatus="Sell limits selected.";UpdateDisplay();return;}
   if(sparam==OSPName("BOTH")){ospMode=2;ospStatus="Both sides selected.";UpdateDisplay();return;}
   if(sparam==OSPName("SYNC")){OSPSync();ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;}
   if(sparam==OSPName("PAUSE"))
   {
      if(ospRunning){ospPaused=!ospPaused;ospStatus=ospPaused?"Engine paused.":"Engine resumed.";}
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }
   if(sparam==OSPName("CLOSE")){OSPCloseAll();ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;}
   if(sparam==OSPName("START"))
   {
      if(!ospRunning&& !OSPSync()){ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;}
      ospRunning=!ospRunning;
      if(ospRunning){ospPaused=false;ospLastBar=iTime(_Symbol,_Period,0);OSPDeletePending();OSPRefreshClosedCandle();}
      else ospStatus="Stopped. Existing orders remain.";
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }

   if(sparam=="UI_B_SYNC"){ if(SyncBuy()) bSyncFlash=TimeCurrent()+2;ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return; }
   if(sparam=="UI_S_SYNC"){ if(SyncSell()) sSyncFlash=TimeCurrent()+2;ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return; }
   if(sparam=="UI_B_SUBMIT_SL")
   {
      SyncControlInputs();
      ApplyManualSLLock(1);
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }
   if(sparam=="UI_S_SUBMIT_SL")
   {
      SyncControlInputs();
      ApplyManualSLLock(-1);
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }
   if(sparam=="UI_B_RESTART")
   {
      if(bBasketOn) RestartSideFromMarket(1);
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }
   if(sparam=="UI_S_RESTART")
   {
      if(sBasketOn) RestartSideFromMarket(-1);
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }
   if(sparam=="UI_B_BASKET_ON")
   {
      SyncControlInputs();
      bBasketOn=!bBasketOn;
      if(!bBasketOn)bBasketClosed=false;
      SaveState();
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }
   if(sparam=="UI_S_BASKET_ON")
   {
      SyncControlInputs();
      sBasketOn=!sBasketOn;
      if(!sBasketOn)sBasketClosed=false;
      SaveState();
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }
   if(sparam=="UI_B_AUTOSR")
   {
      SyncControlInputs();
      bAutoSR=!bAutoSR;
      if(bAutoSR) ApplyAutoSRSide(true);
      else SaveState();
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }
   if(sparam=="UI_S_AUTOSR")
   {
      SyncControlInputs();
      sAutoSR=!sAutoSR;
      if(sAutoSR) ApplyAutoSRSide(false);
      else SaveState();
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }
   if(sparam=="UI_B_OPP_ON")
   {
      SyncControlInputs();
      bOppOn=!bOppOn;
      SaveState();
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }
   if(sparam=="UI_S_OPP_ON")
   {
      SyncControlInputs();
      sOppOn=!sOppOn;
      SaveState();
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }

   if(sparam=="UI_B_START")
   {
      if(SyncBuy())
      {
         currBuyM++;bOn=true;bPaused=false;ResetBuyRunState();
         if(bStart<=0){ bStartReached=true;bStartAbove=false; }
         else
         {
            double cur=NormalizeDouble(SymbolInfoDouble(_Symbol,SYMBOL_ASK),_Digits);
            double st=NormalizeDouble(bStart,_Digits);
            bStartAbove=(st>cur);bStartReached=bStartAbove?(cur>=st):(cur<=st);
         }
         SaveState();
      }
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }
   if(sparam=="UI_S_START")
   {
      if(SyncSell())
      {
         currSellM++;sOn=true;sPaused=false;ResetSellRunState();
         if(sStart<=0){ sStartReached=true;sStartAbove=false; }
         else
         {
            double cur=NormalizeDouble(SymbolInfoDouble(_Symbol,SYMBOL_BID),_Digits);
            double st=NormalizeDouble(sStart,_Digits);
            sStartAbove=(st>cur);sStartReached=sStartAbove?(cur>=st):(cur<=st);
         }
         SaveState();
      }
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
   }

   if(sparam=="UI_B_PAUSE"){ if(bOn)bPaused=!bPaused;SaveState();ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return; }
   if(sparam=="UI_S_PAUSE"){ if(sOn)sPaused=!sPaused;SaveState();ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return; }
   if(sparam=="UI_B_REPEAT"){ bRepeat=!bRepeat;SaveState();ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return; }
   if(sparam=="UI_S_REPEAT"){ sRepeat=!sRepeat;SaveState();ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return; }
   if(sparam=="UI_B_CLOSE"){ bOn=false;bPaused=false;CloseAllBuyPositions();ResetBuyRunState();bCloseFlash=TimeCurrent()+2;SaveState();ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return; }
   if(sparam=="UI_S_CLOSE"){ sOn=false;sPaused=false;CloseAllSellPositions();ResetSellRunState();sCloseFlash=TimeCurrent()+2;SaveState();ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return; }

   for(int i=0;i<bGapCount;i++)
   {
      if(sparam=="UI_B_GAPON"+(string)i)
      {
         bool wasOn=bGapOn[i];
         bool rowValid=GapInputValid(true,i);
         if(SyncBuy())
         {
            if(wasOn)
            {
               bGapOn[i]=false;
               if(i==0){ bActive[i]=false;bGap2PullbackStart=0; }
               if(IsProSIndex(i)&&bTicket[i]==0) ResetProSStart(true,i);
            }
            else if(rowValid)
            {
               bGapOn[i]=true;
               if(IsProSIndex(i)) ResetProSStart(true,i);
            }
            else
               bGapOn[i]=false;
            if(i==0&&bGapOn[i]&&bOn&&bStartReached&&bTicket[i]==0&&!bActive[i])
            {
               double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
               TryArmBuyGap(i,bStuck1,ask,TimeCurrent());
            }
            SaveState();
         }
         ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
      }
   }
   for(int i=0;i<sGapCount;i++)
   {
      if(sparam=="UI_S_GAPON"+(string)i)
      {
         bool wasOn=sGapOn[i];
         bool rowValid=GapInputValid(false,i);
         if(SyncSell())
         {
            if(wasOn)
            {
               sGapOn[i]=false;
               if(i==0){ sActive[i]=false;sGap2PullbackStart=0; }
               if(IsProSIndex(i)&&sTicket[i]==0) ResetProSStart(false,i);
            }
            else if(rowValid)
            {
               sGapOn[i]=true;
               if(IsProSIndex(i)) ResetProSStart(false,i);
            }
            else
               sGapOn[i]=false;
            if(i==0&&sGapOn[i]&&sOn&&sStartReached&&sTicket[i]==0&&!sActive[i])
            {
               double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
               TryArmSellGap(i,sStuck1,bid,TimeCurrent());
            }
            SaveState();
         }
         ObjectSetInteger(0,sparam,OBJPROP_STATE,false);UpdateDisplay();return;
      }
   }
}
//+------------------------------------------------------------------+
