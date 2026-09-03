//+------------------------------------------------------------------+
//|              Quantora Break Even Manager MT5                     |
//|           Professional Trading Utility for MetaTrader 5          |
//|                                                                  |
//| Copyright © 2026 Quantora                                        |
//| https://www.mql5.com/en/users/quantora/seller                    |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2026 Quantora"
#property link      "https://www.mql5.com/en/users/quantora/seller"
#property version   "1.01"
#property strict
#property description "Professional automatic break-even manager for MetaTrader 5."
#property description "Manages manual trades, all positions or a selected Magic Number."

#include <Trade/Trade.mqh>

//============================== ENUMS ======================================
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
input ENUM_Q_SCOPE        InpScope                   = Q_CURRENT_SYMBOL;
input ENUM_Q_MAGIC_FILTER InpMagicFilter             = Q_MANUAL_ONLY;
input ulong               InpSpecificMagic           = 0;
input bool                InpManageBuyPositions      = true;
input bool                InpManageSellPositions     = true;

input group "========== BREAK EVEN SETTINGS =========="
input bool                InpUseBreakEven            = true;
input int                 InpBreakEvenTriggerPoints  = 400;
input int                 InpBreakEvenOffsetPoints   = 30;
input int                 InpMinimumStepPoints       = 10;

input group "========== EXECUTION =========="
input bool                InpUseTimer                = true;
input int                 InpTimerSeconds            = 1;
input bool                InpEnablePrintLog          = true;

input group "========== DASHBOARD =========="
input bool                InpShowPanel               = true;
input ENUM_BASE_CORNER    InpPanelCorner             = CORNER_LEFT_UPPER;
input int                 InpPanelX                  = 15;
input int                 InpPanelY                  = 145;

//============================== CONSTANTS ==================================
#define Q_VERSION "1.01"
#define Q_PREFIX  "QBEM_"

color CLR_BG      = C'8,23,38';
color CLR_GOLD    = C'212,175,55';
color CLR_WHITE   = C'245,245,245';
color CLR_GRAY    = C'169,176,184';
color CLR_GREEN   = C'0,200,83';
color CLR_RED     = C'255,82,82';
color CLR_BORDER  = C'70,86,104';

//============================== STATE ======================================
CTrade trade;
bool   g_manager_enabled=true;
string g_status="ACTIVE";
int    g_modified_count=0;
int    g_error_count=0;

//============================== HELPERS ====================================
void LogMessage(const string text)
  {
   if(InpEnablePrintLog)
      Print("[Quantora Break Even Manager MT5] ",text);
  }

string ScopeText()
  {
   return(InpScope==Q_CURRENT_SYMBOL ? "CURRENT SYMBOL" : "ALL SYMBOLS");
  }

string FilterText()
  {
   if(InpMagicFilter==Q_MANUAL_ONLY)
      return "MANUAL ONLY";
   if(InpMagicFilter==Q_SPECIFIC_MAGIC)
      return "MAGIC "+IntegerToString((long)InpSpecificMagic);
   return "ALL POSITIONS";
  }

string AccountTypeText()
  {
   long mode=AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(mode==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      return "HEDGING";
   if(mode==ACCOUNT_MARGIN_MODE_RETAIL_NETTING)
      return "NETTING";
   return "EXCHANGE";
  }

bool IsManagedType(const ENUM_POSITION_TYPE type)
  {
   if(type==POSITION_TYPE_BUY && !InpManageBuyPositions)
      return false;
   if(type==POSITION_TYPE_SELL && !InpManageSellPositions)
      return false;
   return true;
  }

bool MatchesPosition()
  {
   string symbol=PositionGetString(POSITION_SYMBOL);
   long magic=PositionGetInteger(POSITION_MAGIC);
   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   if(InpScope==Q_CURRENT_SYMBOL && symbol!=_Symbol)
      return false;
   if(!IsManagedType(type))
      return false;

   if(InpMagicFilter==Q_MANUAL_ONLY && magic!=0)
      return false;
   if(InpMagicFilter==Q_SPECIFIC_MAGIC && (ulong)magic!=InpSpecificMagic)
      return false;

   return true;
  }

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

double MatchedFloatingProfit()
  {
   double total=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;
      if(!MatchesPosition())
         continue;
      total+=PositionGetDouble(POSITION_PROFIT);
      total+=PositionGetDouble(POSITION_SWAP);
     }
   return total;
  }

int SymbolDigitsSafe(const string symbol)
  {
   return (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
  }

double NormalizePrice(const string symbol,const double price)
  {
   return NormalizeDouble(price,SymbolDigitsSafe(symbol));
  }

bool IsStopDistanceValid(const string symbol,
                         const ENUM_POSITION_TYPE type,
                         const double sl)
  {
   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   double bid=SymbolInfoDouble(symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(symbol,SYMBOL_ASK);
   int stops=(int)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
   int freeze=(int)SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double minimum=MathMax(stops,freeze)*point;

   if(type==POSITION_TYPE_BUY)
      return (sl<=bid-minimum);
   return (sl>=ask+minimum);
  }

bool ModifyPosition(const ulong ticket,
                    const string symbol,
                    const double new_sl,
                    const double tp)
  {
   ResetLastError();
   double normalized_sl=NormalizePrice(symbol,new_sl);
   double normalized_tp=(tp>0.0 ? NormalizePrice(symbol,tp) : 0.0);

   if(trade.PositionModify(ticket,normalized_sl,normalized_tp))
     {
      g_modified_count++;
      LogMessage("Break even applied. Ticket="+IntegerToString((long)ticket)+
                 " SL="+DoubleToString(normalized_sl,SymbolDigitsSafe(symbol)));
      return true;
     }

   g_error_count++;
   LogMessage("PositionModify failed. Ticket="+IntegerToString((long)ticket)+
              " Retcode="+IntegerToString((int)trade.ResultRetcode())+
              " Message="+trade.ResultRetcodeDescription());
   return false;
  }

bool ApplyBreakEvenToSelectedPosition(const ulong ticket)
  {
   if(ticket==0 || !PositionSelectByTicket(ticket))
      return false;
   if(!MatchesPosition())
      return false;

   string symbol=PositionGetString(POSITION_SYMBOL);
   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double open_price=PositionGetDouble(POSITION_PRICE_OPEN);
   double old_sl=PositionGetDouble(POSITION_SL);
   double tp=PositionGetDouble(POSITION_TP);
   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   double bid=SymbolInfoDouble(symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(symbol,SYMBOL_ASK);
   double current=(type==POSITION_TYPE_BUY ? bid : ask);
   double profit_points=(type==POSITION_TYPE_BUY)
                        ? (current-open_price)/point
                        : (open_price-current)/point;

   if(profit_points<InpBreakEvenTriggerPoints)
      return false;

   double candidate=(type==POSITION_TYPE_BUY)
                    ? open_price+InpBreakEvenOffsetPoints*point
                    : open_price-InpBreakEvenOffsetPoints*point;

   bool improves=false;
   if(type==POSITION_TYPE_BUY)
      improves=(old_sl<=0.0 || candidate>old_sl+InpMinimumStepPoints*point);
   else
      improves=(old_sl<=0.0 || candidate<old_sl-InpMinimumStepPoints*point);

   if(!improves)
      return false;
   if(!IsStopDistanceValid(symbol,type,candidate))
      return false;

   return ModifyPosition(ticket,symbol,candidate,tp);
  }

void ManagePositions()
  {
   if(!g_manager_enabled || !InpUseBreakEven)
      return;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      ApplyBreakEvenToSelectedPosition(ticket);
     }
  }

void BreakEvenAllNow()
  {
   int before=g_modified_count;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;
      if(!MatchesPosition())
         continue;

      string symbol=PositionGetString(POSITION_SYMBOL);
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open_price=PositionGetDouble(POSITION_PRICE_OPEN);
      double old_sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
      double candidate=(type==POSITION_TYPE_BUY)
                       ? open_price+InpBreakEvenOffsetPoints*point
                       : open_price-InpBreakEvenOffsetPoints*point;

      bool improves=(type==POSITION_TYPE_BUY)
                    ? (old_sl<=0.0 || candidate>old_sl)
                    : (old_sl<=0.0 || candidate<old_sl);

      if(improves && IsStopDistanceValid(symbol,type,candidate))
         ModifyPosition(ticket,symbol,candidate,tp);
     }

   g_status=(g_modified_count>before ? "BREAK EVEN APPLIED" : "NO ELIGIBLE POSITION");
  }

//============================== UI HELPERS =================================
void DeletePanel()
  {
   ObjectsDeleteAll(0,Q_PREFIX);
   ChartRedraw();
  }

void SetCommonObjectProperties(const string name)
  {
   ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
  }

void CreateRect(const string name,const int x,const int y,
                const int width,const int height,
                const color bg,const color border)
  {
   ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   SetCommonObjectProperties(name);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,width);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,height);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,border);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
  }

void CreateLabel(const string name,const string text,
                 const int x,const int y,const int size,
                 const color clr,const bool bold=false)
  {
   ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   SetCommonObjectProperties(name);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,size);
   ObjectSetString(0,name,OBJPROP_FONT,bold ? "Arial Bold" : "Arial");
   ObjectSetString(0,name,OBJPROP_TEXT,text);
  }

void CreateButton(const string name,const string text,
                  const int x,const int y,const int width,
                  const int height,const color bg)
  {
   ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,width);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,height);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,CLR_GOLD);
   ObjectSetInteger(0,name,OBJPROP_COLOR,CLR_WHITE);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
   ObjectSetString(0,name,OBJPROP_FONT,"Arial Bold");
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
  }

void BuildPanel()
  {
   if(!InpShowPanel)
      return;

   DeletePanel();

   int x=InpPanelX;
   int y=InpPanelY;
   int w=440;
   int h=430;

   CreateRect(Q_PREFIX+"BG",x,y,w,h,CLR_BG,CLR_GOLD);
   CreateLabel(Q_PREFIX+"BRAND","QUANTORA",x+18,y+14,14,CLR_GOLD,true);
   CreateLabel(Q_PREFIX+"SUBTITLE","Professional Trading Tool",x+18,y+40,10,CLR_WHITE);
   CreateLabel(Q_PREFIX+"VERSION","MT5  v"+Q_VERSION,x+350,y+18,10,CLR_GRAY,true);

   CreateRect(Q_PREFIX+"LINE1",x+18,y+66,w-36,1,CLR_GOLD,CLR_GOLD);

   CreateLabel(Q_PREFIX+"STATUS","Status: "+g_status,x+18,y+82,11,CLR_WHITE,true);
   CreateLabel(Q_PREFIX+"BALANCE","Balance: 0.00",x+18,y+112,10,CLR_WHITE);
   CreateLabel(Q_PREFIX+"EQUITY","Equity: 0.00",x+18,y+137,10,CLR_WHITE);
   CreateLabel(Q_PREFIX+"MARGIN","Free Margin: 0.00",x+18,y+162,10,CLR_WHITE);
   CreateLabel(Q_PREFIX+"SYMBOL","Current Symbol: "+_Symbol,x+18,y+187,10,CLR_WHITE);
   CreateLabel(Q_PREFIX+"SPREAD","Spread: 0",x+230,y+112,10,CLR_WHITE);
   CreateLabel(Q_PREFIX+"ACCOUNT","Account Type: "+AccountTypeText(),x+230,y+137,10,CLR_WHITE);
   CreateLabel(Q_PREFIX+"MAGIC","Magic Number: "+FilterText(),x+230,y+162,10,CLR_WHITE);
   CreateLabel(Q_PREFIX+"RISK","Trigger: "+IntegerToString(InpBreakEvenTriggerPoints)+" points",x+230,y+187,10,CLR_WHITE);

   CreateRect(Q_PREFIX+"LINE2",x+18,y+218,w-36,1,CLR_BORDER,CLR_BORDER);

   CreateLabel(Q_PREFIX+"SCOPE","Scope: "+ScopeText(),x+18,y+235,10,CLR_GRAY);
   CreateLabel(Q_PREFIX+"FILTER","Filter: "+FilterText(),x+18,y+258,10,CLR_GRAY);
   CreateLabel(Q_PREFIX+"POSITIONS","Managed Positions: 0",x+230,y+235,10,CLR_GRAY);
   CreateLabel(Q_PREFIX+"FLOAT","Floating P/L: 0.00",x+230,y+258,10,CLR_GRAY);
   CreateLabel(Q_PREFIX+"OFFSET","Break Even Offset: "+IntegerToString(InpBreakEvenOffsetPoints)+" points",x+18,y+285,10,CLR_GRAY);
   CreateLabel(Q_PREFIX+"COUNT","Applied: 0   Errors: 0",x+230,y+285,10,CLR_GRAY);

   CreateRect(Q_PREFIX+"LINE3",x+18,y+315,w-36,1,CLR_BORDER,CLR_BORDER);

   CreateButton(Q_PREFIX+"TOGGLE","STOP MANAGER",x+18,y+333,190,42,CLR_RED);
   CreateButton(Q_PREFIX+"BE","BREAK EVEN NOW",x+232,y+333,190,42,C'37,87,132');

   CreateLabel(Q_PREFIX+"FOOT","mql5.com/en/users/quantora/seller",x+18,y+397,9,CLR_GOLD);
   ChartRedraw();
  }

void UpdatePanel()
  {
   if(!InpShowPanel)
      return;

   double spread=(SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/_Point;
   double floating=MatchedFloatingProfit();
   int managed_positions=CountMatchedPositions();

   // Show clearly whether the utility is stopped, waiting or monitoring trades.
   if(!g_manager_enabled)
      g_status="STOPPED";
   else if(managed_positions<=0)
      g_status="WAITING - NO MATCHED POSITION";
   else
      g_status="MONITORING "+IntegerToString(managed_positions)+" POSITION(S)";

   ObjectSetString(0,Q_PREFIX+"STATUS",OBJPROP_TEXT,"Status: "+g_status);
   ObjectSetInteger(0,Q_PREFIX+"STATUS",OBJPROP_COLOR,g_manager_enabled ? CLR_GREEN : CLR_RED);
   ObjectSetString(0,Q_PREFIX+"BALANCE",OBJPROP_TEXT,"Balance: "+DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2));
   ObjectSetString(0,Q_PREFIX+"EQUITY",OBJPROP_TEXT,"Equity: "+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2));
   ObjectSetString(0,Q_PREFIX+"MARGIN",OBJPROP_TEXT,"Free Margin: "+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE),2));
   ObjectSetString(0,Q_PREFIX+"SYMBOL",OBJPROP_TEXT,"Current Symbol: "+_Symbol);
   ObjectSetString(0,Q_PREFIX+"SPREAD",OBJPROP_TEXT,"Spread: "+DoubleToString(spread,1));
   ObjectSetString(0,Q_PREFIX+"ACCOUNT",OBJPROP_TEXT,"Account Type: "+AccountTypeText());
   ObjectSetString(0,Q_PREFIX+"MAGIC",OBJPROP_TEXT,"Magic Number: "+FilterText());
   ObjectSetString(0,Q_PREFIX+"POSITIONS",OBJPROP_TEXT,"Managed Positions: "+IntegerToString(managed_positions));
   ObjectSetString(0,Q_PREFIX+"FLOAT",OBJPROP_TEXT,"Floating P/L: "+DoubleToString(floating,2));
   ObjectSetInteger(0,Q_PREFIX+"FLOAT",OBJPROP_COLOR,floating>=0.0 ? CLR_GREEN : CLR_RED);
   ObjectSetString(0,Q_PREFIX+"COUNT",OBJPROP_TEXT,"Applied: "+IntegerToString(g_modified_count)+"   Errors: "+IntegerToString(g_error_count));
   ObjectSetString(0,Q_PREFIX+"TOGGLE",OBJPROP_TEXT,g_manager_enabled ? "STOP MANAGER" : "START MANAGER");
   ObjectSetInteger(0,Q_PREFIX+"TOGGLE",OBJPROP_BGCOLOR,g_manager_enabled ? CLR_RED : CLR_GREEN);
   ChartRedraw();
  }

//============================== EVENTS =====================================
int OnInit()
  {
   if(InpBreakEvenTriggerPoints<0 || InpBreakEvenOffsetPoints<0 || InpMinimumStepPoints<0)
     {
      Print("Invalid break-even input values.");
      return INIT_PARAMETERS_INCORRECT;
     }

   trade.SetAsyncMode(false);
   trade.SetTypeFillingBySymbol(_Symbol);

   BuildPanel();
   UpdatePanel();

   if(InpUseTimer)
      EventSetTimer((int)MathMax(1,InpTimerSeconds));

   LogMessage("Initialized successfully. Version "+Q_VERSION);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   DeletePanel();
   LogMessage("Removed from chart. Reason="+IntegerToString(reason));
  }

void OnTick()
  {
   ManagePositions();
   if(!InpUseTimer)
      UpdatePanel();
  }

void OnTimer()
  {
   ManagePositions();
   UpdatePanel();
  }

void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
  {
   if(id!=CHARTEVENT_OBJECT_CLICK)
      return;

   if(sparam==Q_PREFIX+"TOGGLE")
     {
      g_manager_enabled=!g_manager_enabled;
      g_status=g_manager_enabled ? "ACTIVE" : "STOPPED";
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      UpdatePanel();
     }
   else if(sparam==Q_PREFIX+"BE")
     {
      BreakEvenAllNow();
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      UpdatePanel();
     }
  }

//===========================================================
// Developed by Quantora
//
// More Professional Trading Robots
//
// https://www.mql5.com/en/users/quantora/seller
//===========================================================
