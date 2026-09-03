//+------------------------------------------------------------------+
//|                                              Spread Monitor.mq5  |
//|                                  Copyright 2026, Marian Beceanu  |
//|                           https://www.mql5.com/en/users/zorbacc  | 
// |                                Email: marian.beceanu@gmail.com  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Marian Beceanu"
#property link      "https://www.mql5.com/en/users/zorbacc"
#property link      "https://www.mql5.com"
#property version   "5.02"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

// Enumeration for panel background color options (Dropdown)
enum ENUM_PANEL_BG
{
   BG_TerminalDark  = 0, // Terminal Dark (Bloomberg / LSEG Style)
   BG_NavyExecutive = 1, // Deep Navy Professional
   BG_CharcoalSteel = 2, // Dark Slate Steel
   BG_MatteBlack    = 3  // Absolute Matte Black
};

// Configuration parameters (Fully in English)
input group "=== ENGINE PARAMETERS ==="
input int         InpPeriod       = 40;              // Rolling statistical period
input double      InpZScoreHigh   = 1.8;             // Toxic flow / High risk slippage threshold
input double      InpZScoreLow    = -1.2;            // Optimal compression threshold for Market Making

input group "=== DASHBOARD UI SETTINGS ==="
input int         InpTextSize     = 9;               // Font size (Scale-aware)
input ENUM_PANEL_BG InpPanelColor = BG_TerminalDark; // Panel background color (Dropdown)

// Unique prefix for graphical objects
string prefix = "Pro_Spread_Dash_";

//+------------------------------------------------------------------+
int OnInit()
  {
   // 100ms millisecond timer for instantaneous tick-by-tick real-time sync
   EventSetMillisecondTimer(100);
   CreateDashboardUI();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < InpPeriod) return(0);

   ProcessAnalyticsAndRender(spread, rates_total);

   return(rates_total);
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   int rates = Bars(_Symbol, _Period);
   if(rates < InpPeriod) return;
   
   int spreadArr[];
   ArraySetAsSeries(spreadArr, true);
   
   // Corecție critică: Copiere sigură și completă a bufferului de spread din chart
   int copied = CopySpread(_Symbol, _Period, 0, InpPeriod, spreadArr);
   if(copied > 0)
     {
      ProcessAnalyticsAndRender(spreadArr, copied);
     }
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, prefix);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
color GetPanelBackground()
  {
   switch(InpPanelColor)
     {
      case BG_TerminalDark:  return C'12,14,18';
      case BG_NavyExecutive: return C'9,18,32';
      case BG_CharcoalSteel: return C'24,28,34';
      case BG_MatteBlack:    return C'5,5,5';
      default:               return C'12,14,18';
     }
  }

//+------------------------------------------------------------------+
void CreateDashboardUI()
  {
   ObjectsDeleteAll(0, prefix);
   
   int rowHeight = InpTextSize + 14;
   int totalRows = 8;
   
   int panelHeight = 55 + (totalRows * rowHeight) + 25;
   int panelWidth  = 480 + (InpTextSize * 14); 

   // 1. Main Background Panel
   string bgName = prefix + "BG";
   ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, 15);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE, panelWidth);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, panelHeight);
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, GetPanelBackground());
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, C'70,80,95'); 
   ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bgName, OBJPROP_BACK, false);

   // 2. Panel Title
   string titleName = prefix + "Title";
   ObjectCreate(0, titleName, OBJ_LABEL, 0, 0, 0);
   ObjectSetString(0, titleName, OBJPROP_TEXT, "=== SPREAD ANALYTICS MONITOR ===");
   ObjectSetString(0, titleName, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, titleName, OBJPROP_FONTSIZE, InpTextSize + 1);
   ObjectSetInteger(0, titleName, OBJPROP_COLOR, C'230,190,70');
   ObjectSetInteger(0, titleName, OBJPROP_XDISTANCE, 25);
   ObjectSetInteger(0, titleName, OBJPROP_YDISTANCE, 30);
   ObjectSetInteger(0, titleName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
  }

//+------------------------------------------------------------------+
void ProcessAnalyticsAndRender(const int &spread[], int total_bars)
  {
   if(total_bars <= 0) return;
   
   double sum = 0;
   double sumSq = 0;
   int count = 0;
   
   int limit = (total_bars < InpPeriod) ? total_bars : InpPeriod;
   
   for(int j = 0; j < limit; j++)
     {
      double sp = (double)spread[j];
      sum += sp;
      count++;
     }
   
   double mean = (count > 0) ? sum / count : 0;
   
   for(int j = 0; j < limit; j++)
     {
      double diff = (double)spread[j] - mean;
      sumSq += diff * diff;
     }
   
   double variance = (count > 0) ? sumSq / count : 0;
   double stdDev = MathSqrt(variance);
   
   // Preluare sigură și robustă a spread-ului live (cu fallback direct pe elementul 0 din array dacă brokerul nu returnează valoarea instant pe simbol)
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread <= 0 && total_bars > 0) currentSpread = (long)spread[0];
   
   double zScore = (stdDev > 0) ? ((double)currentSpread - mean) / stdDev : 0;

   // Calcul Min / Max istoric în fereastra activă
   long minSp = currentSpread;
   long maxSp = currentSpread;
   
   for(int j = 0; j < limit; j++)
     {
      if((long)spread[j] < minSp) minSp = (long)spread[j];
      if((long)spread[j] > maxSp) maxSp = (long)spread[j];
     }

   // Regim de Piață
   string regime = "NORMAL LIQUIDITY";
   color regimeColor = clrLightGray;
   
   if(zScore <= InpZScoreLow)
     {
      regime = "COMPRESSED (Optimal MM Entry)";
      regimeColor = clrLimeGreen;
     }
   else if(zScore >= InpZScoreHigh)
     {
      regime = "TOXIC FLOW / HIGH RISK (Wide)";
      regimeColor = clrOrangeRed;
     }

   double relPct = (mean > 0) ? (100.0 * (double)currentSpread / mean) : 100.0;

   // Construire rânduri de date
   string labels[8];
   labels[0] = StringFormat("Live Spread (Points) : %d pts", (int)currentSpread);
   labels[1] = StringFormat("Rolling Mean (Prd %d)  : %.2f pts", InpPeriod, mean);
   labels[2] = StringFormat("Relative Spread (%)  : %.1f%% of Avg", relPct);
   labels[3] = StringFormat("Standard Deviation   : %.2f", stdDev);
   labels[4] = StringFormat("Z-Score Statistic    : %.2f", zScore);
   labels[5] = StringFormat("Min / Max Window     : %d / %d pts", minSp, maxSp);
   labels[6] = StringFormat("Instrument Asset     : %s (%s)", _Symbol, EnumToString(_Period));
   labels[7] = StringFormat("Market Regime        : %s", regime);

   int rowHeight = InpTextSize + 14; 

   for(int k = 0; k < 8; k++)
     {
      string name = prefix + "Line_" + IntegerToString(k);
      
      if(ObjectFind(0, name) < 0)
        {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetString(0, name, OBJPROP_FONT, "Arial");
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpTextSize);
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 25);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
        }
      
      ObjectSetString(0, name, OBJPROP_TEXT, labels[k]);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 60 + (k * rowHeight));
      
      if(k == 7)
         ObjectSetInteger(0, name, OBJPROP_COLOR, regimeColor);
      else if(k == 0)
         ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
      else
         ObjectSetInteger(0, name, OBJPROP_COLOR, C'205,215,230');
     }
     
   ChartRedraw(0);
  }