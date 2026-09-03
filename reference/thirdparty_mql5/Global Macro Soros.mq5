//+------------------------------------------------------------------+
//|                                          Global Macro Soros.mq5  |
//|                                  Copyright 2026, Marian Beceanu  |
//|                           https://www.mql5.com/en/users/zorbacc  | 
// |                                Email: marian.beceanu@gmail.com  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Marian Beceanu"
#property link      "https://www.mql5.com/en/users/zorbacc"
#property link      "https://www.mql5.com"
#property version   "2.10"
#property indicator_separate_window
#property indicator_buffers 2
#property indicator_plots   1
#property indicator_minimum -3.5
#property indicator_maximum  3.5
#property strict

#property indicator_label1  "Macro Bias Score"
#property indicator_type1   DRAW_COLOR_HISTOGRAM
#property indicator_color1  clrGray, clrLimeGreen, clrRed
#property indicator_width1  3

//--- inputs
input group "=== Trend Detection ==="
input int             InpFastMA   = 50;         // Fast MA period used to detect trend direction
input int             InpSlowMA   = 200;        // Slow MA period used to detect trend direction
input ENUM_MA_METHOD  InpMAMethod = MODE_EMA;    // MA method applied on all three timeframes

input group "=== Macro Timeframes ==="
input ENUM_TIMEFRAMES InpTF_Short  = PERIOD_H4;  // Short-term macro timeframe
input ENUM_TIMEFRAMES InpTF_Medium = PERIOD_D1;  // Medium-term macro timeframe
input ENUM_TIMEFRAMES InpTF_Long   = PERIOD_W1;  // Long-term macro timeframe

input group "=== Dashboard ==="
input bool InpShowDashboard = true;   // Show the on-chart dashboard panel
input int  InpPanelX        = 10;     // Panel horizontal offset (pixels)
input int  InpPanelY        = 10;     // Panel vertical offset (pixels)
input int  InpFontSize      = 9;      // Panel text size (6-24)

//--- indicator buffers
double ScoreBuf[];
double ColorBuf[];

//--- MA handles: fast/slow per macro timeframe
int hFastShort  = INVALID_HANDLE, hSlowShort  = INVALID_HANDLE;
int hFastMedium = INVALID_HANDLE, hSlowMedium = INVALID_HANDLE;
int hFastLong   = INVALID_HANDLE, hSlowLong   = INVALID_HANDLE;

//--- last known good values, used as a fallback if a CopyBuffer call
//--- momentarily fails (e.g. higher-timeframe history still loading).
//--- This keeps the panel/histogram stable instead of flashing to
//--- neutral every time a data feed hiccups.
int    g_lastShortDir  = 0;
int    g_lastMediumDir = 0;
int    g_lastLongDir   = 0;
double g_lastScore     = 0;

//--- dashboard state
string   PFX          = "GMS_INST_";
string   SHORT_NAME    = "GlobalMacro_Soros_INSTITUTIONAL";
int      g_subWin       = -1;     // this indicator's subwindow index, resolved lazily
bool     g_dashboardOn  = false;
double   g_scale         = 1.0;    // panel geometry scale (from InpFontSize + DPI)
double   g_dpiScale      = 1.0;

//--- throttling cache: labels are only rewritten when their text actually changes
string g_c_short="", g_c_medium="", g_c_long="", g_c_score="", g_c_time="";

//+------------------------------------------------------------------+
//| Input parameter validation                                        |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   if(InpFastMA < 1)
     { Print("ERROR: InpFastMA must be >= 1."); return(false); }
   if(InpSlowMA < 2)
     { Print("ERROR: InpSlowMA must be >= 2."); return(false); }
   if(InpFastMA >= InpSlowMA)
     { Print("ERROR: InpFastMA must be smaller than InpSlowMA."); return(false); }
   if(InpFontSize < 6 || InpFontSize > 24)
     { Print("ERROR: InpFontSize must be between 6 and 24."); return(false); }
   return(true);
  }

//+------------------------------------------------------------------+
//| Geometry scale from InpFontSize + screen DPI (same convention as  |
//| the other indicators in the suite)                                 |
//+------------------------------------------------------------------+
double ComputeScale()
  {
   long dpi = TerminalInfoInteger(TERMINAL_SCREEN_DPI);
   if(dpi <= 0) dpi = 96;
   g_dpiScale = (double)dpi / 96.0;
   if(g_dpiScale < 0.6) g_dpiScale = 0.6;
   if(g_dpiScale > 2.5) g_dpiScale = 2.5;

   double s = ((double)InpFontSize / 9.0) * g_dpiScale;
   if(s < 0.5) s = 0.5;
   if(s > 3.0) s = 3.0;
   return(s);
  }

int SX(double baseVal) { int v = (int)MathRound(baseVal * g_scale); return(v < 1 ? 1 : v); }
int FontPt() { int v = (int)MathRound(InpFontSize * g_dpiScale); if(v < 5) v = 5; if(v > 72) v = 72; return(v); }

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);

   bool ok = true;
   ok &= SetIndexBuffer(0, ScoreBuf, INDICATOR_DATA);
   ok &= SetIndexBuffer(1, ColorBuf, INDICATOR_COLOR_INDEX);
   if(!ok)
     {
      Print("ERROR: allocating the indicator buffers failed.");
      return(INIT_FAILED);
     }

   // Only the current/live bar ever holds a real score (see OnCalculate).
   // Every other bar must stay EMPTY so the histogram never back-fills the
   // whole chart with "today's" reading.
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   ResetLastError();
   hFastShort  = iMA(_Symbol, InpTF_Short,  InpFastMA, 0, InpMAMethod, PRICE_CLOSE);
   hSlowShort  = iMA(_Symbol, InpTF_Short,  InpSlowMA, 0, InpMAMethod, PRICE_CLOSE);
   hFastMedium = iMA(_Symbol, InpTF_Medium, InpFastMA, 0, InpMAMethod, PRICE_CLOSE);
   hSlowMedium = iMA(_Symbol, InpTF_Medium, InpSlowMA, 0, InpMAMethod, PRICE_CLOSE);
   hFastLong   = iMA(_Symbol, InpTF_Long,   InpFastMA, 0, InpMAMethod, PRICE_CLOSE);
   hSlowLong   = iMA(_Symbol, InpTF_Long,   InpSlowMA, 0, InpMAMethod, PRICE_CLOSE);

   if(hFastShort == INVALID_HANDLE || hSlowShort == INVALID_HANDLE ||
      hFastMedium == INVALID_HANDLE || hSlowMedium == INVALID_HANDLE ||
      hFastLong == INVALID_HANDLE || hSlowLong == INVALID_HANDLE)
     {
      Print("ERROR: creating the MA handles for GlobalMacro_Soros_INSTITUTIONAL failed, code: ", GetLastError());
      return(INIT_FAILED);
     }

   g_lastShortDir = 0; g_lastMediumDir = 0; g_lastLongDir = 0; g_lastScore = 0;
   g_c_short = ""; g_c_medium = ""; g_c_long = ""; g_c_score = ""; g_c_time = "";
   g_subWin = -1;
   g_dashboardOn = false;
   g_scale = ComputeScale();

   IndicatorSetString(INDICATOR_SHORTNAME, SHORT_NAME);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit - releases every handle and removes all panel objects    |
//| (the base version never released its MA handles - fixed here)    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PFX);

   if(hFastShort  != INVALID_HANDLE) { IndicatorRelease(hFastShort);  hFastShort  = INVALID_HANDLE; }
   if(hSlowShort  != INVALID_HANDLE) { IndicatorRelease(hSlowShort);  hSlowShort  = INVALID_HANDLE; }
   if(hFastMedium != INVALID_HANDLE) { IndicatorRelease(hFastMedium); hFastMedium = INVALID_HANDLE; }
   if(hSlowMedium != INVALID_HANDLE) { IndicatorRelease(hSlowMedium); hSlowMedium = INVALID_HANDLE; }
   if(hFastLong   != INVALID_HANDLE) { IndicatorRelease(hFastLong);   hFastLong   = INVALID_HANDLE; }
   if(hSlowLong   != INVALID_HANDLE) { IndicatorRelease(hSlowLong);   hSlowLong   = INVALID_HANDLE; }
  }

//+------------------------------------------------------------------+
//| Reads fast vs slow MA on a given timeframe and returns +1/0/-1.   |
//| Returns false (without touching outDir) if the data isn't ready   |
//| yet, so the caller can fall back to the last known good value.    |
//+------------------------------------------------------------------+
bool GetTrendDirection(int fastHandle, int slowHandle, int &outDir)
  {
   double fastVal[1], slowVal[1];
   if(CopyBuffer(fastHandle, 0, 0, 1, fastVal) <= 0) return(false);
   if(CopyBuffer(slowHandle, 0, 0, 1, slowVal) <= 0) return(false);
   if(fastVal[0] > slowVal[0]) outDir = 1;
   else if(fastVal[0] < slowVal[0]) outDir = -1;
   else outDir = 0;
   return(true);
  }

//+------------------------------------------------------------------+
//| Locates the subwindow this indicator is running in, so the        |
//| dashboard panel can be drawn in the correct window even if the    |
//| user reorders indicator subwindows.                                |
//+------------------------------------------------------------------+
int FindSubWindow()
  {
   int winTotal = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);
   for(int w = 0; w < winTotal; w++)
     {
      int total = ChartIndicatorsTotal(0, w);
      for(int k = 0; k < total; k++)
        {
         if(ChartIndicatorName(0, w, k) == SHORT_NAME)
            return(w);
        }
     }
   return(-1);
  }

//+------------------------------------------------------------------+
//| Creates a text label inside the indicator's subwindow             |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int xAbs, int yAbs, color clr, int fontSize)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, g_subWin, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, xAbs);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, yAbs);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| Updates a label only if its text actually changed (throttling -   |
//| avoids needless redraws on every tick)                            |
//+------------------------------------------------------------------+
void SetLabelIfChanged(string name, string newText, color clr, string &cache)
  {
   if(newText == cache)
      return;
   if(ObjectFind(0, name) < 0)
      return;
   ObjectSetString(0, name, OBJPROP_TEXT, newText);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   cache = newText;
  }

//+------------------------------------------------------------------+
//| Lightweight flat background rectangle for the panel               |
//+------------------------------------------------------------------+
void CreatePanelBackground(int x, int y, int width, int height)
  {
   string name = PFX + "bg";
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, g_subWin, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'30,30,30');
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrDimGray);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| Builds the dashboard panel (background + all labels)              |
//+------------------------------------------------------------------+
void CreateDashboard()
  {
   int font = FontPt();
   int px = SX(InpPanelX);
   int py = SX(InpPanelY);
   int width  = SX(230);
   int height = SX(112);

   CreatePanelBackground(px - SX(6), py - SX(6), width, height);

   CreateLabel(PFX + "title", "GLOBAL MACRO (Soros)", px, py, clrDeepSkyBlue, font);
   CreateLabel(PFX + "short",  "", px, py + SX(20), clrWhite, font);
   CreateLabel(PFX + "medium", "", px, py + SX(38), clrWhite, font);
   CreateLabel(PFX + "long",   "", px, py + SX(56), clrWhite, font);
   CreateLabel(PFX + "score",  "", px, py + SX(76), clrWhite, font);
   CreateLabel(PFX + "time",   "", px, py + SX(94), clrSilver, font);

   g_c_short = ""; g_c_medium = ""; g_c_long = ""; g_c_score = ""; g_c_time = "";
   g_dashboardOn = true;
  }

//+------------------------------------------------------------------+
//| Returns a readable "UP / DOWN / FLAT" label + color for a         |
//| direction value (+1/0/-1)                                         |
//+------------------------------------------------------------------+
void DirLabel(int dir, string &text, color &clr)
  {
   if(dir > 0)      { text = "UP";   clr = clrLimeGreen; }
   else if(dir < 0) { text = "DOWN"; clr = clrRed; }
   else             { text = "FLAT"; clr = clrSilver; }
  }

//+------------------------------------------------------------------+
//| Refreshes the dashboard panel content (throttled)                 |
//+------------------------------------------------------------------+
void UpdateDashboard(int shortDir, int mediumDir, int longDir, double score, datetime lastTime)
  {
   if(!InpShowDashboard)
      return;

   if(g_subWin < 0)
     {
      g_subWin = FindSubWindow();
      if(g_subWin < 0)
         return; // subwindow not created yet - retry on the next tick
     }

   double newScale = ComputeScale();
   if(!g_dashboardOn || ObjectFind(0, PFX + "bg") < 0 || MathAbs(newScale - g_scale) > 0.01)
     {
      g_scale = newScale;
      CreateDashboard();
     }

   string sText, mText, lText; color sClr, mClr, lClr;
   DirLabel(shortDir,  sText, sClr);
   DirLabel(mediumDir, mText, mClr);
   DirLabel(longDir,   lText, lClr);

   string biasText;
   color  biasColor;
   if(score >= 2)       { biasText = "MACRO BULLISH";  biasColor = clrLimeGreen; }
   else if(score <= -2) { biasText = "MACRO BEARISH";  biasColor = clrRed; }
   else                 { biasText = "NEUTRAL / MIXED"; biasColor = clrKhaki; }

   SetLabelIfChanged(PFX + "short",  StringFormat("Short  (%s): %s", EnumToString(InpTF_Short),  sText), sClr, g_c_short);
   SetLabelIfChanged(PFX + "medium", StringFormat("Medium (%s): %s", EnumToString(InpTF_Medium), mText), mClr, g_c_medium);
   SetLabelIfChanged(PFX + "long",   StringFormat("Long   (%s): %s", EnumToString(InpTF_Long),   lText), lClr, g_c_long);
   SetLabelIfChanged(PFX + "score",  StringFormat("Score: %.0f  =>  %s", score, biasText), biasColor, g_c_score);
   SetLabelIfChanged(PFX + "time",   "Last update: " + TimeToString(lastTime, TIME_DATE|TIME_MINUTES), clrSilver, g_c_time);
  }

//+------------------------------------------------------------------+
//| OnCalculate                                                        |
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
   if(rates_total < 1)
      return(0);

   // On a fresh attach/reload (prev_calculated == 0), wipe the whole buffer to
   // EMPTY first. This is the fix for the "everything is green" bug: the old
   // code looped from bar 0 to rates_total-1 and painted every single
   // historical bar with TODAY's score, making the entire chart look bullish
   // (or bearish) regardless of what actually happened in the past.
   if(prev_calculated == 0)
     {
      ArrayInitialize(ScoreBuf, EMPTY_VALUE);
      ArrayInitialize(ColorBuf, 0);
     }

   int start = MathMax(prev_calculated - 1, 0);
   if(start >= rates_total)
      start = rates_total - 1;

   int shortDir = g_lastShortDir, mediumDir = g_lastMediumDir, longDir = g_lastLongDir;
   int tmpDir;

   // Resilient reads: on failure (e.g. history for that timeframe still
   // downloading) keep the last known good value instead of forcing 0/neutral.
   if(GetTrendDirection(hFastShort,  hSlowShort,  tmpDir)) { shortDir  = tmpDir; g_lastShortDir  = tmpDir; }
   if(GetTrendDirection(hFastMedium, hSlowMedium, tmpDir)) { mediumDir = tmpDir; g_lastMediumDir = tmpDir; }
   if(GetTrendDirection(hFastLong,   hSlowLong,   tmpDir)) { longDir   = tmpDir; g_lastLongDir   = tmpDir; }

   double score = shortDir + mediumDir + longDir;
   g_lastScore = score;

   // This is a LIVE gauge, not a historical series: the fast/slow MA reads
   // above only ever reflect the present moment, so only the current
   // (last) bar is allowed to carry a real value. Any bar re-touched by this
   // recalculation range, other than the last one, is cleared instead of
   // being stamped with the present score.
   int last = rates_total - 1;
   for(int i = start; i < last; i++)
     {
      ScoreBuf[i] = EMPTY_VALUE;
      ColorBuf[i] = 0;
     }
   ScoreBuf[last] = score;
   ColorBuf[last] = (score > 0) ? 1 : (score < 0 ? 2 : 0);

   UpdateDashboard(shortDir, mediumDir, longDir, score, time[last]);

   return(rates_total);
  }
