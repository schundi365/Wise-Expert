//+------------------------------------------------------------------+
//|                    Quantora Trade Manager MT5                     |
//|          Open-source position management utility for MT5          |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Quantora"
#property link      "https://www.mql5.com/en/users/quantora/seller"
#property version   "1.02"
#property strict
#property description "Automatic SL/TP, break-even and trailing manager for MT5."
#property description "Manages manual trades and/or positions filtered by magic number."

#include <Trade/Trade.mqh>

enum ENUM_Q_SCOPE
  {
   Q_CURRENT_SYMBOL=0,
   Q_ALL_SYMBOLS=1
  };

enum ENUM_Q_MAGIC_FILTER
  {
   Q_MANUAL_ONLY=0,
   Q_ALL_POSITIONS=1,
   Q_SPECIFIC_MAGIC=2
  };

//============================== INPUTS =====================================
input group "========== POSITION SCOPE =========="
input ENUM_Q_SCOPE        InpScope                  = Q_CURRENT_SYMBOL;
input ENUM_Q_MAGIC_FILTER InpMagicFilter            = Q_MANUAL_ONLY;
input ulong               InpSpecificMagic          = 0;
input bool                InpManageBuyPositions     = true;
input bool                InpManageSellPositions    = true;

input group "========== AUTOMATIC SL / TP =========="
input bool                InpSetMissingStopLoss     = true;
input int                 InpStopLossPoints         = 500;
input bool                InpSetMissingTakeProfit   = true;
input int                 InpTakeProfitPoints       = 1000;

input group "========== BREAK EVEN =========="
input bool                InpUseBreakEven           = true;
input int                 InpBreakEvenTriggerPoints = 400;
input int                 InpBreakEvenOffsetPoints  = 30;

input group "========== TRAILING STOP =========="
input bool                InpUseTrailingStop        = true;
input int                 InpTrailingStartPoints    = 600;
input int                 InpTrailingDistancePoints = 350;
input int                 InpTrailingStepPoints     = 50;

input group "========== ACCOUNT PROTECTION =========="
input bool                InpUseDailyLossLimit      = false;
input double              InpDailyLossLimitMoney    = 100.0;
input bool                InpCloseAllAtDailyLoss    = false;
input bool                InpUseDailyProfitTarget   = false;
input double              InpDailyProfitTargetMoney = 200.0;
input bool                InpCloseAllAtDailyProfit  = false;

input group "========== PANEL =========="
input bool                InpShowPanel              = true;
input ENUM_BASE_CORNER    InpPanelCorner            = CORNER_LEFT_UPPER;
input int                 InpPanelX                 = 15;
input int                 InpPanelY                 = 145;

//============================== STATE ======================================
CTrade trade;
string g_prefix="QTM_";
bool   g_manager_enabled=true;
datetime g_day_start=0;
double g_day_start_balance=0.0;
string g_status="ACTIVE";

//============================== HELPERS ====================================
void RefreshDayStart()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   dt.hour=0;
   dt.min=0;
   dt.sec=0;

   datetime today=StructToTime(dt);

   if(today!=g_day_start)
     {
      g_day_start=today;
      g_day_start_balance=AccountInfoDouble(ACCOUNT_BALANCE);
     }
  }

//+------------------------------------------------------------------+
double DailyResult()
  {
   RefreshDayStart();

   double result=0.0;

   if(!HistorySelect(g_day_start,TimeCurrent()))
      return AccountInfoDouble(ACCOUNT_EQUITY)-g_day_start_balance;

   int deals=HistoryDealsTotal();

   for(int i=0;i<deals;i++)
     {
      ulong ticket=HistoryDealGetTicket(i);

      if(ticket==0)
         continue;

      ENUM_DEAL_ENTRY entry=
         (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY);

      if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY)
         continue;

      result+=HistoryDealGetDouble(ticket,DEAL_PROFIT);
      result+=HistoryDealGetDouble(ticket,DEAL_SWAP);
      result+=HistoryDealGetDouble(ticket,DEAL_COMMISSION);
     }

   // Include currently floating result.
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);

      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;

      result+=PositionGetDouble(POSITION_PROFIT);
      result+=PositionGetDouble(POSITION_SWAP);
     }

   return result;
  }

//+------------------------------------------------------------------+
bool MatchesPosition()
  {
   string symbol=PositionGetString(POSITION_SYMBOL);

   if(InpScope==Q_CURRENT_SYMBOL && symbol!=_Symbol)
      return false;

   ENUM_POSITION_TYPE type=
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   if(type==POSITION_TYPE_BUY && !InpManageBuyPositions)
      return false;

   if(type==POSITION_TYPE_SELL && !InpManageSellPositions)
      return false;

   ulong magic=(ulong)PositionGetInteger(POSITION_MAGIC);

   if(InpMagicFilter==Q_MANUAL_ONLY && magic!=0)
      return false;

   if(InpMagicFilter==Q_SPECIFIC_MAGIC && magic!=InpSpecificMagic)
      return false;

   return true;
  }

//+------------------------------------------------------------------+
double NormalizePrice(const string symbol,const double price)
  {
   return NormalizeDouble(price,
                          (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS));
  }

//+------------------------------------------------------------------+
double MinimumStopDistance(const string symbol)
  {
   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   long stops=SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freeze=SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL);

   return MathMax((double)stops,(double)freeze)*point;
  }

//+------------------------------------------------------------------+
bool ModifyPosition(const ulong ticket,
                    const string symbol,
                    double sl,
                    double tp)
  {
   sl=(sl>0.0 ? NormalizePrice(symbol,sl) : 0.0);
   tp=(tp>0.0 ? NormalizePrice(symbol,tp) : 0.0);

   if(!trade.PositionModify(ticket,sl,tp))
     {
      Print("Modify failed #",ticket,
            " ",symbol,
            ": ",trade.ResultRetcodeDescription());
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
void EnsureInitialStops(const ulong ticket)
  {
   string symbol=PositionGetString(POSITION_SYMBOL);
   ENUM_POSITION_TYPE type=
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   double open=PositionGetDouble(POSITION_PRICE_OPEN);
   double current_sl=PositionGetDouble(POSITION_SL);
   double current_tp=PositionGetDouble(POSITION_TP);
   double min_distance=MinimumStopDistance(symbol);

   double new_sl=current_sl;
   double new_tp=current_tp;

   if(InpSetMissingStopLoss &&
      current_sl<=0.0 &&
      InpStopLossPoints>0)
     {
      double distance=MathMax(InpStopLossPoints*point,min_distance);

      new_sl=(type==POSITION_TYPE_BUY)
             ? open-distance
             : open+distance;
     }

   if(InpSetMissingTakeProfit &&
      current_tp<=0.0 &&
      InpTakeProfitPoints>0)
     {
      double distance=MathMax(InpTakeProfitPoints*point,min_distance);

      new_tp=(type==POSITION_TYPE_BUY)
             ? open+distance
             : open-distance;
     }

   if(new_sl!=current_sl || new_tp!=current_tp)
      ModifyPosition(ticket,symbol,new_sl,new_tp);
  }

//+------------------------------------------------------------------+
void ApplyBreakEven(const ulong ticket)
  {
   if(!InpUseBreakEven ||
      InpBreakEvenTriggerPoints<=0)
      return;

   string symbol=PositionGetString(POSITION_SYMBOL);
   ENUM_POSITION_TYPE type=
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   double open=PositionGetDouble(POSITION_PRICE_OPEN);
   double old_sl=PositionGetDouble(POSITION_SL);
   double tp=PositionGetDouble(POSITION_TP);

   MqlTick tick;

   if(!SymbolInfoTick(symbol,tick))
      return;

   double current=(type==POSITION_TYPE_BUY ? tick.bid : tick.ask);
   double favorable=(type==POSITION_TYPE_BUY)
                    ? current-open
                    : open-current;

   if(favorable<InpBreakEvenTriggerPoints*point)
      return;

   double offset=InpBreakEvenOffsetPoints*point;
   double candidate=(type==POSITION_TYPE_BUY)
                    ? open+offset
                    : open-offset;

   bool improves=(type==POSITION_TYPE_BUY)
                 ? (old_sl<=0.0 || candidate>old_sl+point)
                 : (old_sl<=0.0 || candidate<old_sl-point);

   if(!improves)
      return;

   double min_distance=MinimumStopDistance(symbol);

   if(type==POSITION_TYPE_BUY &&
      tick.bid-candidate<min_distance)
      candidate=tick.bid-min_distance;

   if(type==POSITION_TYPE_SELL &&
      candidate-tick.ask<min_distance)
      candidate=tick.ask+min_distance;

   ModifyPosition(ticket,symbol,candidate,tp);
  }

//+------------------------------------------------------------------+
void ApplyTrailing(const ulong ticket)
  {
   if(!InpUseTrailingStop ||
      InpTrailingStartPoints<=0 ||
      InpTrailingDistancePoints<=0)
      return;

   string symbol=PositionGetString(POSITION_SYMBOL);
   ENUM_POSITION_TYPE type=
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   double open=PositionGetDouble(POSITION_PRICE_OPEN);
   double old_sl=PositionGetDouble(POSITION_SL);
   double tp=PositionGetDouble(POSITION_TP);

   MqlTick tick;

   if(!SymbolInfoTick(symbol,tick))
      return;

   double current=(type==POSITION_TYPE_BUY ? tick.bid : tick.ask);
   double favorable=(type==POSITION_TYPE_BUY)
                    ? current-open
                    : open-current;

   if(favorable<InpTrailingStartPoints*point)
      return;

   double distance=InpTrailingDistancePoints*point;
   double candidate=(type==POSITION_TYPE_BUY)
                    ? current-distance
                    : current+distance;

   double step=MathMax(1,InpTrailingStepPoints)*point;

   bool improves=(type==POSITION_TYPE_BUY)
                 ? (old_sl<=0.0 || candidate>=old_sl+step)
                 : (old_sl<=0.0 || candidate<=old_sl-step);

   if(!improves)
      return;

   double min_distance=MinimumStopDistance(symbol);

   if(type==POSITION_TYPE_BUY &&
      tick.bid-candidate<min_distance)
      candidate=tick.bid-min_distance;

   if(type==POSITION_TYPE_SELL &&
      candidate-tick.ask<min_distance)
      candidate=tick.ask+min_distance;

   ModifyPosition(ticket,symbol,candidate,tp);
  }

//+------------------------------------------------------------------+
void ManagePositions()
  {
   if(!g_manager_enabled)
      return;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);

      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;

      if(!MatchesPosition())
         continue;

      EnsureInitialStops(ticket);

      // Refresh selection because the first modification may have changed SL/TP.
      if(!PositionSelectByTicket(ticket))
         continue;

      ApplyBreakEven(ticket);

      if(!PositionSelectByTicket(ticket))
         continue;

      ApplyTrailing(ticket);
     }
  }

//+------------------------------------------------------------------+
bool CloseMatchedPositions()
  {
   bool ok=true;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);

      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;

      if(!MatchesPosition())
         continue;

      if(!trade.PositionClose(ticket))
        {
         Print("Close failed #",ticket,
               ": ",trade.ResultRetcodeDescription());
         ok=false;
        }
     }

   return ok;
  }

//+------------------------------------------------------------------+
void CheckAccountProtection()
  {
   double daily=DailyResult();

   if(InpUseDailyLossLimit &&
      InpDailyLossLimitMoney>0.0 &&
      daily<=-InpDailyLossLimitMoney)
     {
      g_status="DAILY LOSS LIMIT";

      if(InpCloseAllAtDailyLoss)
         CloseMatchedPositions();

      g_manager_enabled=false;
      return;
     }

   if(InpUseDailyProfitTarget &&
      InpDailyProfitTargetMoney>0.0 &&
      daily>=InpDailyProfitTargetMoney)
     {
      g_status="DAILY PROFIT TARGET";

      if(InpCloseAllAtDailyProfit)
         CloseMatchedPositions();

      g_manager_enabled=false;
     }
  }

//============================== PANEL ======================================
void DeletePanel()
  {
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
     {
      string name=ObjectName(0,i);

      if(StringFind(name,g_prefix)==0)
         ObjectDelete(0,name);
     }
  }

//+------------------------------------------------------------------+
void CreateRect(const string name,
                const int x,
                const int y,
                const int width,
                const int height,
                const color bg,
                const color border)
  {
   ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,width);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,height);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,border);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
  }

//+------------------------------------------------------------------+
void CreateLabel(const string name,
                 const string text,
                 const int x,
                 const int y,
                 const int size,
                 const color clr)
  {
   ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,size);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetString(0,name,OBJPROP_FONT,"Arial");
   ObjectSetString(0,name,OBJPROP_TEXT,text);
  }

//+------------------------------------------------------------------+
void CreateButton(const string name,
                  const string text,
                  const int x,
                  const int y,
                  const int width,
                  const int height,
                  const color bg)
  {
   ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,width);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,height);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
  }

//+------------------------------------------------------------------+
int CountMatchedPositions()
  {
   int count=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);

      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;

      if(MatchesPosition())
         count++;
     }

   return count;
  }

//+------------------------------------------------------------------+
double MatchedFloatingProfit()
  {
   double result=0.0;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);

      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;

      if(!MatchesPosition())
         continue;

      result+=PositionGetDouble(POSITION_PROFIT);
      result+=PositionGetDouble(POSITION_SWAP);
     }

   return result;
  }

//+------------------------------------------------------------------+
string ScopeText()
  {
   return InpScope==Q_CURRENT_SYMBOL ? "CURRENT SYMBOL" : "ALL SYMBOLS";
  }

//+------------------------------------------------------------------+
string FilterText()
  {
   if(InpMagicFilter==Q_MANUAL_ONLY)
      return "MANUAL ONLY";

   if(InpMagicFilter==Q_SPECIFIC_MAGIC)
      return "MAGIC "+IntegerToString((long)InpSpecificMagic);

   return "ALL POSITIONS";
  }

//+------------------------------------------------------------------+
void BuildPanel()
  {
   if(!InpShowPanel)
      return;

   DeletePanel();

   int x=InpPanelX;
   int y=InpPanelY;

   CreateRect(g_prefix+"BG",x,y,470,245,C'5,14,24',C'197,151,56');

   CreateLabel(g_prefix+"TITLE",
               "QUANTORA TRADE MANAGER",
               x+18,y+14,16,C'234,189,76');

   CreateLabel(g_prefix+"VER","MT5  v1.02",
               x+365,y+18,9,clrSilver);

   CreateLabel(g_prefix+"STATUS","STATUS: "+g_status,
               x+18,y+55,10,clrWhite);

   CreateLabel(g_prefix+"SCOPE","SCOPE: "+ScopeText(),
               x+18,y+82,9,clrSilver);

   CreateLabel(g_prefix+"FILTER","FILTER: "+FilterText(),
               x+235,y+82,9,clrSilver);

   CreateLabel(g_prefix+"POS","POSITIONS: 0",
               x+18,y+118,10,clrWhite);

   CreateLabel(g_prefix+"FLOAT","FLOATING P/L: 0.00",
               x+170,y+118,10,clrWhite);

   CreateLabel(g_prefix+"DAILY","DAILY P/L: 0.00",
               x+340,y+118,10,clrWhite);

   CreateButton(g_prefix+"TOGGLE",
                "STOP MANAGER",
                x+18,y+164,135,38,C'135,45,45');

   CreateButton(g_prefix+"CLOSE",
                "CLOSE MATCHED",
                x+166,y+164,135,38,C'105,70,25');

   CreateButton(g_prefix+"BE",
                "BREAK EVEN NOW",
                x+314,y+164,135,38,C'35,105,75');

   CreateLabel(g_prefix+"FOOT",
               "Quantora Store: mql5.com/en/users/quantora/seller",
               x+18,y+218,9,C'234,189,76');

   ChartRedraw();
  }

//+------------------------------------------------------------------+
void BreakEvenAllNow()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);

      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;

      if(!MatchesPosition())
         continue;

      string symbol=PositionGetString(POSITION_SYMBOL);
      ENUM_POSITION_TYPE type=
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double old_sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
      double candidate=(type==POSITION_TYPE_BUY)
                       ? open+InpBreakEvenOffsetPoints*point
                       : open-InpBreakEvenOffsetPoints*point;

      bool improves=(type==POSITION_TYPE_BUY)
                    ? (old_sl<=0.0 || candidate>old_sl)
                    : (old_sl<=0.0 || candidate<old_sl);

      if(improves)
         ModifyPosition(ticket,symbol,candidate,tp);
     }
  }

//+------------------------------------------------------------------+
void UpdatePanel()
  {
   if(!InpShowPanel)
      return;

   ObjectSetString(0,g_prefix+"STATUS",OBJPROP_TEXT,
                   "STATUS: "+g_status);

   ObjectSetString(0,g_prefix+"POS",OBJPROP_TEXT,
                   "POSITIONS: "+IntegerToString(CountMatchedPositions()));

   ObjectSetString(0,g_prefix+"FLOAT",OBJPROP_TEXT,
                   "FLOATING P/L: "+DoubleToString(MatchedFloatingProfit(),2));

   ObjectSetString(0,g_prefix+"DAILY",OBJPROP_TEXT,
                   "DAILY P/L: "+DoubleToString(DailyResult(),2));

   ObjectSetString(0,g_prefix+"TOGGLE",OBJPROP_TEXT,
                   g_manager_enabled ? "STOP MANAGER" : "START MANAGER");

   ObjectSetInteger(0,g_prefix+"TOGGLE",OBJPROP_BGCOLOR,
                    g_manager_enabled ? C'135,45,45' : C'35,105,75');

   ChartRedraw();
  }

//============================== EVENTS =====================================
int OnInit()
  {
   trade.SetAsyncMode(false);
   RefreshDayStart();

   BuildPanel();
   EventSetTimer(1);

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   DeletePanel();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   CheckAccountProtection();
   ManagePositions();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   CheckAccountProtection();
   ManagePositions();
   UpdatePanel();
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
  {
   if(id!=CHARTEVENT_OBJECT_CLICK)
      return;

   if(sparam==g_prefix+"TOGGLE")
     {
      g_manager_enabled=!g_manager_enabled;
      g_status=g_manager_enabled ? "ACTIVE" : "STOPPED";
      UpdatePanel();
     }
   else if(sparam==g_prefix+"CLOSE")
     {
      CloseMatchedPositions();
      g_status="MATCHED POSITIONS CLOSED";
      UpdatePanel();
     }
   else if(sparam==g_prefix+"BE")
     {
      BreakEvenAllNow();
      g_status="BREAK EVEN APPLIED";
      UpdatePanel();
     }
  }
//+------------------------------------------------------------------+
