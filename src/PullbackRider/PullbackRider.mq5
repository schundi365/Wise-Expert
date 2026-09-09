//+------------------------------------------------------------------+
//| PullbackRider.mq5   v1.00                                        |
//| Clean single-position trend-following pullback EA.               |
//|                                                                  |
//| NO grid, NO martingale, NO averaging, NO opposite hedge.         |
//| At most ONE position open at a time.                             |
//|                                                                  |
//| Edge idea: in an established trend (slow MA sloping + price on    |
//| the trend side of it), wait for a pullback to a fast MA, then    |
//| enter ONE position when price resumes in the trend direction.    |
//| Initial stop = k*ATR. Ride with an ATR trailing stop. Optional   |
//| fixed R take-profit. Risk-% position sizing with a lot ceiling.  |
//|                                                                  |
//| This is the honest expression of "buy the dip in an uptrend":    |
//| one bet, defined risk, let the trend pay, cut fast if wrong.     |
//+------------------------------------------------------------------+
#property copyright "Wise Trader project - PullbackRider"
#property version   "1.00"
#property description "Single-position trend pullback rider: slow-MA trend + fast-MA pullback entry, ATR stop/trail, risk-% sizing. No grid/martingale."

#include <Trade/Trade.mqh>

//--- inputs ---------------------------------------------------------
input group "Trend filter (slow MA)"
input int    InpSlowMaPeriod = 200;          // Slow MA period (the trend)
input ENUM_MA_METHOD InpSlowMaMethod = MODE_EMA; // Slow MA method
input ENUM_TIMEFRAMES InpTrendTF   = PERIOD_H1;  // Trend timeframe
input int    InpSlopeLookback = 5;           // Bars back to measure slow-MA slope (must be rising/falling)

input group "Pullback entry (fast MA)"
input int    InpFastMaPeriod = 20;           // Fast MA period (the pullback target)
input ENUM_MA_METHOD InpFastMaMethod = MODE_EMA; // Fast MA method
input ENUM_TIMEFRAMES InpEntryTF   = PERIOD_M15; // Entry timeframe
input int    InpPullbackMaxBars = 6;         // Pullback must have touched fast MA within this many bars

input group "Risk / exits (ATR based)"
input int    InpAtrPeriod    = 14;           // ATR period (entry TF)
input double InpAtrStopMult  = 1.5;          // Initial stop = entry -/+ this * ATR
input int    InpMinStopPts   = 200;          // Minimum stop distance in points (floors tiny-ATR sizing blowups)
input double InpAtrTrailMult = 2.5;          // Trailing stop distance = this * ATR (0 = no trail)
input double InpTpRMult      = 0.0;          // Take profit at this many R (0 = ride the trail only)
input bool   InpMoveToBE     = true;         // Move stop to break-even once +1R
input double InpBEOffsetR    = 0.1;          // Break-even lock offset, in R (0.1 = +0.1R locked)

input group "Position sizing"
input double InpRiskPct      = 0.5;          // Risk % of equity per trade (sizing from stop distance)
input double InpFixedLot     = 0.0;          // If > 0, use this fixed lot and ignore RiskPct
input double InpMaxLot       = 1.0;          // Hard lot ceiling (safety)

input group "Guards"
input int    InpMaxSpreadPts = 60;           // Skip entries when spread exceeds this (points; 0 = off)
input int    InpStartHour    = 0;            // Trading window start hour (server), inclusive
input int    InpEndHour      = 24;           // Trading window end hour (server), exclusive (24 = all day)
input bool   InpOneTradePerBar = true;       // At most one entry attempt per entry-TF bar

input group "Engine"
input long   InpMagic        = 77010001;     // Magic number
input int    InpSlippage     = 30;           // Max deviation, points
input bool   InpEnableLog    = true;         // Log to Experts tab
input int    InpHeartbeatSecs = 60;          // Heartbeat log interval (seconds) so you can see it's alive

//--- state
CTrade   m_trade;
string   m_sym;
double   m_point;
int      m_digits;
double   m_tickValue;
double   m_tickSize;
double   m_lotStep;
double   m_minLot;
double   m_maxLotBroker;
int      m_slowH = INVALID_HANDLE;
int      m_fastH = INVALID_HANDLE;
int      m_atrH  = INVALID_HANDLE;
datetime m_lastBar = 0;                       // last processed entry-TF bar time
double   m_entryRisk = 0.0;                   // R in price terms for the open position (for BE/partial)

void Log(const string s){ if(InpEnableLog) Print("[PBR] ", s); }
double Ask(){ return SymbolInfoDouble(m_sym,SYMBOL_ASK); }
double Bid(){ return SymbolInfoDouble(m_sym,SYMBOL_BID); }
double Nz(double p){ return NormalizeDouble(p,m_digits); }

//====================================================================
//  INIT
//====================================================================
int OnInit()
  {
   m_sym=_Symbol;
   m_point =SymbolInfoDouble(m_sym,SYMBOL_POINT);
   m_digits=(int)SymbolInfoInteger(m_sym,SYMBOL_DIGITS);
   m_tickValue=SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_VALUE);
   m_tickSize =SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_SIZE);
   m_lotStep  =SymbolInfoDouble(m_sym,SYMBOL_VOLUME_STEP);
   m_minLot   =SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MIN);
   m_maxLotBroker=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MAX);

   m_slowH=iMA(m_sym,InpTrendTF,InpSlowMaPeriod,0,InpSlowMaMethod,PRICE_CLOSE);
   m_fastH=iMA(m_sym,InpEntryTF,InpFastMaPeriod,0,InpFastMaMethod,PRICE_CLOSE);
   m_atrH =iATR(m_sym,InpEntryTF,InpAtrPeriod);
   if(m_slowH==INVALID_HANDLE || m_fastH==INVALID_HANDLE || m_atrH==INVALID_HANDLE)
     { Print("[PBR] indicator handle failed"); return INIT_FAILED; }

   m_trade.SetExpertMagicNumber(InpMagic);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFillingBySymbol(m_sym);

   //--- Heartbeat timer so you can SEE it's alive between (infrequent) trades.
   EventSetTimer(MathMax(10,InpHeartbeatSecs));

   //--- ALWAYS-ON startup banner (not gated by InpEnableLog) so attaching gives
   //--- immediate confirmation in the Experts tab that the EA loaded and is running.
   PrintFormat("[PBR] ATTACHED & RUNNING on %s. slowMA=%d(%s) fastMA=%d(%s) ATR=%d stop=%.1fx trail=%.1fx tpR=%.1f risk=%.2f%% | AlgoTrading=%s",
        m_sym,InpSlowMaPeriod,EnumToString(InpTrendTF),InpFastMaPeriod,EnumToString(InpEntryTF),
        InpAtrPeriod,InpAtrStopMult,InpAtrTrailMult,InpTpRMult,InpRiskPct,
        (MQLInfoInteger(MQL_TRADE_ALLOWED)?"ON":"OFF (enable it!)"));
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      Print("[PBR] WARNING: Algo/Auto trading is DISABLED - the EA will evaluate but cannot place trades. Enable the 'Algo Trading' toolbar button.");
   return INIT_SUCCEEDED;
  }
void OnDeinit(const int r)
  {
   EventKillTimer();
   if(m_slowH!=INVALID_HANDLE) IndicatorRelease(m_slowH);
   if(m_fastH!=INVALID_HANDLE) IndicatorRelease(m_fastH);
   if(m_atrH !=INVALID_HANDLE) IndicatorRelease(m_atrH);
  }

//--- Heartbeat: prints current state so you can confirm it's alive and see WHY
//--- it isn't trading (no trend / waiting for pullback / spread too wide).
void OnTimer()
  {
   int dir=TrendDir();
   string trend = (dir>0)?"UP":(dir<0)?"DOWN":"NONE(flat/no-trend => waiting)";
   double sp=(Ask()-Bid())/m_point;
   bool pos=HasPosition();
   string why="";
   if(!pos)
     {
      if(dir==0) why="no trend (slow MA flat or price wrong side)";
      else if(InpMaxSpreadPts>0 && sp>InpMaxSpreadPts) why=StringFormat("spread %.0f > max %d",sp,InpMaxSpreadPts);
      else if(!PullbackTrigger(dir)) why="trend OK, waiting for a pullback+resumption";
      else why="conditions MET - will enter on next bar";
     }
   else why="in a position - managing exit";
   PrintFormat("[PBR] heartbeat: trend=%s spread=%.0fpts position=%s | %s",trend,sp,pos?"YES":"no",why);
  }

//====================================================================
//  HELPERS
//====================================================================
bool HasPosition()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       return true; }
   return false;
  }

double Ind(int h,int shift)
  { double b[]; if(CopyBuffer(h,0,shift,1,b)<1) return 0.0; return b[0]; }

//--- lot from risk % and stop distance (price). Risk sizing is AUTHORITATIVE:
//--- the lot is chosen so a stop-out loses ~InpRiskPct of equity. The MaxLot
//--- ceiling is a SAFETY cap only - if it would force MORE than the intended
//--- risk, we DO NOT take the trade (returning 0) rather than over-risk.
double LotForRisk(double stopDistPrice)
  {
   if(InpFixedLot>0) return NormalizeLot(InpFixedLot);
   if(stopDistPrice<=0 || m_tickValue<=0 || m_tickSize<=0) return 0.0;
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * (InpRiskPct/100.0);
   double lossPerLot = (stopDistPrice/m_tickSize) * m_tickValue;   // money lost per 1.0 lot at stop
   if(lossPerLot<=0) return 0.0;
   double lot = riskMoney / lossPerLot;

   //--- round DOWN to lot step (never round up into more risk)
   if(m_lotStep>0) lot = MathFloor(lot/m_lotStep)*m_lotStep;

   //--- if the risk-correct lot is below the broker minimum, taking min lot would
   //--- risk more than intended. Only allow it if min-lot risk stays within 1.5x.
   if(lot < m_minLot)
     {
      double minRisk = m_minLot * lossPerLot;
      if(minRisk > riskMoney*1.5) { Log(StringFormat("SKIP: min-lot risk %.2f > 1.5x target %.2f",minRisk,riskMoney)); return 0.0; }
      lot = m_minLot;
     }

   //--- MaxLot is a hard safety ceiling. If risk sizing wants MORE than the ceiling,
   //--- cap at the ceiling (do not exceed) - risk stays <= intended, never above.
   double ceil = InpMaxLot>0 ? MathMin(InpMaxLot,m_maxLotBroker) : m_maxLotBroker;
   if(lot>ceil) lot=ceil;
   Log(StringFormat("size: riskMoney=%.2f lossPerLot=%.2f -> lot=%.2f (stopDist=%.*f)",riskMoney,lossPerLot,lot,m_digits,stopDistPrice));
   return lot;
  }
double NormalizeLot(double lot)
  {
   if(m_lotStep>0) lot = MathFloor(lot/m_lotStep)*m_lotStep;
   if(lot<m_minLot) lot=m_minLot;
   double ceil = InpMaxLot>0 ? MathMin(InpMaxLot,m_maxLotBroker) : m_maxLotBroker;
   if(lot>ceil) lot=ceil;
   return lot;
  }

//--- spread + session guards
bool GuardsOk()
  {
   if(InpMaxSpreadPts>0)
     { double sp=(Ask()-Bid())/m_point; if(sp>InpMaxSpreadPts) return false; }
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(!(InpStartHour==0 && InpEndHour>=24))
     { if(dt.hour<InpStartHour || dt.hour>=InpEndHour) return false; }
   return true;
  }

//====================================================================
//  ENTRY LOGIC
//====================================================================
//--- Trend up: slow MA rising over the lookback AND price above slow MA.
//--- Trend dn: slow MA falling AND price below slow MA.
int TrendDir()
  {
   double maNow  = Ind(m_slowH,0);
   double maPast = Ind(m_slowH,InpSlopeLookback);
   if(maNow<=0 || maPast<=0) return 0;
   double px = (Bid()+Ask())/2.0;
   if(maNow>maPast && px>maNow) return +1;
   if(maNow<maPast && px<maNow) return -1;
   return 0;
  }

//--- Did price pull back to the fast MA within the last N closed bars, and has
//--- the most recent CLOSED bar resumed in the trend direction?
//--- For long: some recent bar's low <= fastMA (touched/dipped), and the last
//--- closed bar closed back above the fast MA (resumption).
bool PullbackTrigger(int dir)
  {
   double fast = Ind(m_fastH,1);   // fast MA at last closed bar
   if(fast<=0) return false;

   //--- last closed bar OHLC on entry TF
   double c1 = iClose(m_sym,InpEntryTF,1);
   double o1 = iOpen (m_sym,InpEntryTF,1);
   if(c1<=0) return false;

   //--- touched fast MA within lookback?
   bool touched=false;
   for(int s=1;s<=InpPullbackMaxBars;s++)
     {
      double lo=iLow(m_sym,InpEntryTF,s);
      double hi=iHigh(m_sym,InpEntryTF,s);
      double f =Ind(m_fastH,s);
      if(f<=0) continue;
      if(dir>0 && lo<=f) { touched=true; break; }   // dipped to/through fast MA
      if(dir<0 && hi>=f) { touched=true; break; }
     }
   if(!touched) return false;

   //--- resumption on the last closed bar: closed back on the trend side of fast MA
   //--- and the bar itself is a trend-direction bar (close beyond open).
   if(dir>0) return (c1>fast && c1>o1);
   else      return (c1<fast && c1<o1);
  }

void TryEnter()
  {
   if(HasPosition()) return;
   if(!GuardsOk()) return;
   int dir=TrendDir();
   if(dir==0) return;
   if(!PullbackTrigger(dir)) return;

   double atr=Ind(m_atrH,1);
   if(atr<=0) return;
   double stopDist = InpAtrStopMult*atr;
   //--- floor the stop distance so a tiny ATR can't produce an oversized lot
   double minDist = InpMinStopPts*m_point;
   if(minDist>0 && stopDist<minDist) stopDist=minDist;
   double lot = LotForRisk(stopDist);
   if(lot<=0) return;

   double price = (dir>0)? Ask() : Bid();
   double sl    = (dir>0)? price-stopDist : price+stopDist;
   double tp    = 0.0;
   if(InpTpRMult>0) tp = (dir>0)? price+InpTpRMult*stopDist : price-InpTpRMult*stopDist;
   sl=Nz(sl); tp=Nz(tp);

   bool ok = (dir>0)? m_trade.Buy(lot,m_sym,0,sl,tp,"PBR")
                    : m_trade.Sell(lot,m_sym,0,sl,tp,"PBR");
   if(ok){ m_entryRisk=stopDist;
           Log(StringFormat("%s lot=%.2f entry=%.*f sl=%.*f tp=%.*f atr=%.*f",
                dir>0?"BUY":"SELL",lot,m_digits,price,m_digits,sl,m_digits,tp,m_digits,atr)); }
   else   Log(StringFormat("entry FAILED rc=%u",m_trade.ResultRetcode()));
  }

//====================================================================
//  POSITION MANAGEMENT: break-even + ATR trailing
//====================================================================
void ManageOpen()
  {
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
      double atr  = Ind(m_atrH,1);
      double R    = (m_entryRisk>0)? m_entryRisk : (atr>0? InpAtrStopMult*atr : 0.0);   // risk in price

      double want = sl;

      //--- break-even: once price is +1R, lock stop at entry +/- BE offset
      if(InpMoveToBE && R>0)
        {
         double profitR = lng? (cur-entry)/R : (entry-cur)/R;
         if(profitR>=1.0)
           {
            double be = lng? entry+InpBEOffsetR*R : entry-InpBEOffsetR*R;
            want = lng? MathMax(want,be) : (want==0?be:MathMin(want,be));
           }
        }

      //--- ATR trailing stop
      if(InpAtrTrailMult>0 && atr>0)
        {
         double trail = lng? cur-InpAtrTrailMult*atr : cur+InpAtrTrailMult*atr;
         want = lng? MathMax(want,trail) : (want==0?trail:MathMin(want,trail));
        }

      want=Nz(want);
      bool need = lng? (want>sl+m_point) : (sl==0.0 || want<sl-m_point);
      if(need) m_trade.PositionModify(t,want,tp);
     }
  }

//====================================================================
//  TICK
//====================================================================
void OnTick()
  {
   //--- manage any open position every tick (trailing is price-driven)
   ManageOpen();

   //--- entries evaluated once per new entry-TF bar (avoid intrabar churn)
   datetime bt=iTime(m_sym,InpEntryTF,0);
   if(InpOneTradePerBar)
     { if(bt==m_lastBar) return; m_lastBar=bt; }
   TryEnter();
  }
//+------------------------------------------------------------------+
