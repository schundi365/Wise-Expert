//+------------------------------------------------------------------+
//|                                                GridHedge.mq5     |
//|                    Dual-Sided Grid / Scalp EA with AVS           |
//+------------------------------------------------------------------+
#property copyright "GridHedge EA"
#property link      ""
#property version   "3.10"
#property description "Dual-sided Grid & Scalp EA with Asymmetric Volatility Scaling (AVS)"

#include <Trade\Trade.mqh>
#include <ChartObjects\ChartObjectsLines.mqh>
#include <ChartObjects\ChartObjectsTxt.mqh>

#define LVLS 4

//====================================================================
//  INPUT PARAMETERS
//====================================================================
input group "Base (seeds level 1 + defaults). NOTE: inputs are POINTS; the panel shows/edits PIPS (points/10)."
input double InpLot          = 0.10;    // Base lot per position
input int    InpGapPoints    = 500;     // Base gap, POINTS (500 pts = 50.00 pips on panel)
input double InpTpMoney      = 6.0;     // Profit: close each position at this MONEY profit
input double InpLockMoney    = 50.0;    // Lock/Book: close/book at this MONEY profit (0 = off)
input bool   InpTradeBuy     = true;    // Enable BUY side at start
input bool   InpTradeSell    = true;    // Enable SELL side at start

input group "Management (Prot / B+S)"
input int    InpProtPoints   = 200;     // Prot: arm break-even once position +this pts
input int    InpBSStepPoints = 100;     // B+S: trailing step after break-even, points
input int    InpBeOffsetPoints = 10;    // Break-even offset beyond entry, points

input group "Basket (Start / Target / SL)"
input double InpBuyTarget    = 4550.0;  // BUY target price: book winners, keep top-N (0 = off)
input double InpSellTarget   = 4300.0;  // SELL target price: book winners, keep top-N (0 = off)
input int    InpKeepHedge    = 2;       // How many highest-profit positions to keep on Target
input double InpSideSL       = 0.0;     // Basket SL: close a side if its floating loss <= -this (0 = off)

input group "Scalp mode (high-frequency: keep N slots per side, re-seed after each win)"
input bool   InpScalpMode    = true;    // ON = keep InpScalpSlots positions open per side
input int    InpScalpSlots   = 3;       // Target concurrent positions PER SIDE to keep open
input double InpScalpGapPips = 8.0;     // Tight spacing between scalp entries, in PIPS
input int    InpScalpMinSecs = 5;       // Throttle: minimum seconds between opens on a side

input group "Safety (defaults ON - the floor)"
input int    InpMaxLevels        = 8;     // Max open positions PER SIDE (0 = unlimited)
input double InpMaxFloatingLoss  = 800.0; // Close ALL if combined floating P/L <= -this (0 = off)
input double InpEquityStopPct    = 20.0;  // Close ALL + halt if equity drops this % below start (0 = off)
input double InpBasketTP         = 0.0;   // Close ALL when combined floating P/L >= this (0 = off)
input bool   InpCloseAllOnStop   = true;  // On a safety trip, flatten every position for this magic

input group "Asymmetric Volatility Scaling (AVS)"
input bool            InpEnableAVS         = true;      // Enable Asymmetric Volatility Scaling
input ENUM_TIMEFRAMES InpATRTimeframe      = PERIOD_M1; // ATR Timeframe
input int             InpATRPeriod         = 14;        // ATR Period
input double          InpBaseATR           = 150.0;     // Baseline ATR in Points (e.g. 150 pts = 15 pips)
input double          InpCounterTrendMult  = 0.5;       // Counter-Trend Lot Multiplier (dampen lots on adverse moves)
input double          InpWithTrendMult     = 1.5;       // With-Trend Lot Multiplier (expand lots on trend moves)

input group "Engine"
input long   InpMagic        = 26023332;  // Magic number
input int    InpSlippage     = 30;         // Max deviation, points
input bool   InpStartRunning = true;       // Master START on attach
input bool   InpShowPanel    = true;       // Draw dashboard
input bool   InpEnableLog    = true;       // Log to Experts tab

//--- per-level parameters (Gap2/3/4/ProS)
struct SLevel { int gap; double lot; double tp; double lock; bool on; };

//--- per-side runtime state
struct SSide
  {
   bool   enabled;   
   double target;    
   SLevel lv[LVLS];  
  };

//--- global runtime
struct SLive
  {
   double lot; int gap; double tp; double lock;  
   int    prot; int bs;                           
   double buy_sl; double sell_sl;                 
   double max_loss; double eq_stop_pct;           
   bool   running;                                
   string halt_reason;                           
  };

CTrade         m_trade;
SSide          g_buy_cfg, g_sell_cfg;
SLive          g;
SSide          g_buy, g_sell;
double         m_start_equity = 0.0;
datetime       m_lastOpen[2]  = {0,0};
uint           m_last_draw    = 0;
string         m_sym;
double         m_point;

void Log(const string msg){ if(InpEnableLog) Print("[GridHedge] ",msg); }

//====================================================================
//  AVS & ORDER FUNCTIONS
//====================================================================

//+------------------------------------------------------------------+
//| Calculates Asymmetric Volatility Scaling factor for order lot    |
//+------------------------------------------------------------------+
double GetAVSMultiplier(ENUM_POSITION_TYPE side, int level)
  {
   if(!InpEnableAVS) return 1.0;

   //--- Get current ATR value
   int handle = iATR(_Symbol, InpATRTimeframe, InpATRPeriod);
   if(handle == INVALID_HANDLE) return 1.0;

   double atrVal[];
   ArraySetAsSeries(atrVal, true);
   if(CopyBuffer(handle, 0, 0, 1, atrVal) <= 0)
     {
      IndicatorRelease(handle);
      return 1.0;
     }
   double currentATRPoints = atrVal[0] / _Point;
   IndicatorRelease(handle);

   //--- Determine Volatility Expansion Ratio
   double volRatio = (InpBaseATR > 0) ? (currentATRPoints / InpBaseATR) : 1.0;
   volRatio = MathMin(MathMax(volRatio, 0.5), 3.0); // Clamp between 0.5x and 3.0x

   //--- Identify directional momentum using candle Open vs Close
   double openBar1 = iOpen(_Symbol, InpATRTimeframe, 1);
   double closeBar1 = iClose(_Symbol, InpATRTimeframe, 1);
   bool isBullishTrend = (closeBar1 > openBar1);

   //--- Apply Asymmetric Multiplier based on trade side alignment
   double mult = 1.0;
   if(side == POSITION_TYPE_BUY)
     {
      // Buying into a down-move is counter-trend
      mult = isBullishTrend ? InpWithTrendMult : InpCounterTrendMult;
     }
   else if(side == POSITION_TYPE_SELL)
     {
      // Selling into an up-move is counter-trend
      mult = !isBullishTrend ? InpWithTrendMult : InpCounterTrendMult;
     }

   // Scale adjustment down further for deeper grid levels (level > 3)
   if(level > 3 && !isBullishTrend && side == POSITION_TYPE_BUY)   mult *= 0.8;
   if(level > 3 && isBullishTrend  && side == POSITION_TYPE_SELL)  mult *= 0.8;

   return NormalizeDouble(mult * volRatio, 2);
  }

bool OpenLevel(const ENUM_POSITION_TYPE side,const int level,const double lot)
  {
   // Apply Asymmetric Volatility Scaling (AVS) Factor
   double avsMult = GetAVSMultiplier(side, level);
   double rawLot = lot * avsMult;

   // Enforce broker lot step & min/max bounds
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double scaledLot = MathMin(MathMax(rawLot, minLot), maxLot);
   if(stepLot > 0) scaledLot = MathFloor(scaledLot / stepLot) * stepLot;

   string cmt = StringFormat("P%d_AVS", level); bool ok;
   if(side == POSITION_TYPE_BUY) ok = m_trade.Buy(scaledLot, m_sym, 0, 0, 0, cmt);
   else                         ok = m_trade.Sell(scaledLot, m_sym, 0, 0, 0, cmt);
   
   if(ok) m_lastOpen[side == POSITION_TYPE_BUY ? 0 : 1] = TimeCurrent();   // scalp throttle stamp
   Log(StringFormat("%s %s lot=%.2f (AVS x%.2f): %s rc=%u (%s)",
       (side == POSITION_TYPE_BUY ? "BUY " : "SELL"), cmt, scaledLot, avsMult, (ok ? "OK" : "FAIL"),
       m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription()));
   return ok;
  }

//====================================================================
//  INITIALIZATION & MAIN TICK HANDLER
//====================================================================
int OnInit()
  {
   m_sym   = _Symbol;
   m_point = SymbolInfoDouble(m_sym, SYMBOL_POINT);
   m_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);

   m_trade.SetExpertMagicNumber(InpMagic);
   m_trade.SetDeviationInPoints(InpSlippage);

   g.lot          = InpLot;
   g.gap          = InpGapPoints;
   g.tp           = InpTpMoney;
   g.lock         = InpLockMoney;
   g.prot         = InpProtPoints;
   g.bs           = InpBSStepPoints;
   g.buy_sl       = InpSideSL;
   g.sell_sl      = InpSideSL;
   g.max_loss     = InpMaxFloatingLoss;
   g.eq_stop_pct  = InpEquityStopPct;
   g.running      = InpStartRunning;
   g.halt_reason  = "";

   g_buy.enabled  = InpTradeBuy;
   g_sell.enabled = InpTradeSell;
   g_buy.target   = InpBuyTarget;
   g_sell.target  = InpSellTarget;

   Log(StringFormat("Initialized on %s. Base lot=%.2f, AVS Enabled=%s", 
       m_sym, g.lot, (InpEnableAVS ? "YES" : "NO")));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTick()
  {
   // Basic Execution Logic
   if(!g.running) return;

   // Side Management (Buy & Sell Grid)
   // ... (GridHedge standard position checking and basket updates)
  }