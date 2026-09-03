//+------------------------------------------------------------------+
//|                                           Volatility Regime.mq5  |
//|                                  Copyright 2026, Marian Beceanu  |
//|                           https://www.mql5.com/en/users/zorbacc  | 
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Marian Beceanu"
#property link      "https://www.mql5.com/en/users/zorbacc"
#property link      "https://www.mql5.com"
#property version   "4.10"
#property description "Volatility Regime — regime detection, MTF/volume gated signal,"
#property description "probability confidence meter. Hardened build 4.10:"
#property description "extra input validation, capped first-load workload, safe recalculation"
#property description "state reset, reduced redundant broker calls, explicit chart redraw."
#property indicator_separate_window
#property indicator_buffers 4
#property indicator_plots   2
#property indicator_minimum 0
#property indicator_maximum 100

#property indicator_label1  "Vol %"
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrSilver, clrLime, clrGold, clrOrangeRed, clrRed
#property indicator_width1  2

#property indicator_label2  "Regime"
#property indicator_type2   DRAW_COLOR_HISTOGRAM
#property indicator_color2  C'20,40,20', C'20,50,20', C'50,40,10', C'60,25,10', C'70,15,15'
#property indicator_width2  4

//--- Color enum
enum ENUM_CLR
{
   C_Silver=0, C_White, C_Lime, C_LimeGreen, C_Green,
   C_Gold, C_Orange, C_OrangeRed, C_Red, C_Crimson,
   C_DodgerBlue, C_DeepSkyBlue, C_Gray, C_DimGray, C_Black,
   C_DarkRed, C_DarkSlate
};
color GC(ENUM_CLR c)
{
   switch(c)
   {
      case C_Silver: return clrSilver;
      case C_White: return clrWhite;
      case C_Lime: return clrLime; case C_LimeGreen: return clrLimeGreen;
      case C_Green: return clrGreen; case C_Gold: return clrGold;
      case C_Orange: return clrOrange; case C_OrangeRed: return clrOrangeRed;
      case C_Red: return clrRed; case C_Crimson: return clrCrimson;
      case C_DodgerBlue: return clrDodgerBlue;
      case C_DeepSkyBlue: return clrDeepSkyBlue;
      case C_Gray: return clrGray; case C_DimGray: return clrDimGray;
      case C_Black: return clrBlack; case C_DarkRed: return C'40,10,10';
      case C_DarkSlate: return C'15,15,20';
      default: return clrSilver;
   }
}

//--- Inputs
input group "Core"
input int    InpPeriod       = 14;
input int    InpLookback     = 100;
input int    InpSmooth       = 3;
input group "Volatility"
enum VOL_TYPE {ATR=0, PARKINSON=1, HIST=2};
input VOL_TYPE InpVolType    = PARKINSON;
input group "Regime Levels"
input double InpLow          = 20.0;
input double InpElevated     = 65.0;
input double InpExtreme      = 85.0;
input group "Filters"
input int    InpPersist      = 3;
input bool   InpMTF          = true;
input ENUM_TIMEFRAMES InpMTFPeriod = PERIOD_H1;
input bool   InpVolFilter    = true;
input int    InpVolLookback  = 50;
input double InpLowVolPct    = 25.0;
input group "Signal & Risk"
input int    InpMAPeriod     = 50;
input double InpSL_Mult      = 1.5;
input double InpMinRR        = 1.5;
input double InpTP_RR        = 2.0;
input group "Colors"
input ENUM_CLR InpC_Low      = C_Lime;
input ENUM_CLR InpC_Normal   = C_Silver;
input ENUM_CLR InpC_Elev     = C_Gold;
input ENUM_CLR InpC_High     = C_OrangeRed;
input ENUM_CLR InpC_Extr     = C_Red;
input ENUM_CLR InpC_BG       = C_DarkSlate;
input ENUM_CLR InpC_Text     = C_White;
input ENUM_CLR InpC_Title    = C_Silver;
input ENUM_CLR InpC_Buy      = C_Lime;
input ENUM_CLR InpC_Sell     = C_Red;
input ENUM_CLR InpC_Warn     = C_Orange;
input ENUM_CLR InpC_Muted    = C_DimGray;
input ENUM_CLR InpC_ChartBG  = C_DarkRed;

input group "Visual"
input bool   InpShowDash     = true;
input bool   InpShowBG       = true;
input bool   InpChartBG      = true;
input int    InpFontSize     = 11;
input group "Alerts"
input bool   InpAlertChange  = true;
input bool   InpAlertLow     = true;
input bool   InpAlertExtr    = true;

input group "Performance"
input int    InpDashThrottleMs = 200;
input int    InpMaxInitBars    = 20000;

//--- Probability score
struct SProbScore
{
   double probability;
   string dir;
   color  dirC;
   string grade;
   string confidence;
   string bar;
   string trendLbl;
   color  trendC;
   string momLbl;
   color  momC;
   string riskLbl;
   color  riskC;
   string volLbl;
   color  volC;
};

//--- Buffers & state
double Pct[], Clr[], Reg[], RegClr[];
double Vol[];
double RegDurArr[];
int    atrH = INVALID_HANDLE;
int    maH  = INVALID_HANDLE;
string PF = "VR_";
int    lastReg = -1, pendReg = -1, pendCnt = 0;
uint   lastDashMs = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   string err = "";
   if(InpPeriod<2)                 err += "Period trebuie sa fie >=2. ";
   if(InpLookback<10)              err += "Lookback trebuie sa fie >=10. ";
   if(InpLookback>20000)           err += "Lookback prea mare (max 20000, risc de blocare a terminalului). ";
   if(InpSmooth<1)                 err += "Smooth trebuie sa fie >=1. ";
   if(InpMAPeriod<2)               err += "MAPeriod trebuie sa fie >=2. ";
   if(InpPersist<1)                err += "Persist trebuie sa fie >=1. ";
   if(InpVolLookback<10)           err += "VolLookback trebuie sa fie >=10. ";
   if(InpVolLookback>20000)        err += "VolLookback prea mare (max 20000). ";
   if(InpLow<0 || InpLow>100)      err += "Low trebuie sa fie in [0,100]. ";
   if(InpElevated<0 || InpElevated>100) err += "Elevated trebuie sa fie in [0,100]. ";
   if(InpExtreme<0 || InpExtreme>100)   err += "Extreme trebuie sa fie in [0,100]. ";
   if(!(InpLow < InpElevated && InpElevated < InpExtreme))
      err += "Pragurile de regim trebuie sa fie strict crescatoare: Low < Elevated < Extreme. ";
   if(InpLowVolPct<0 || InpLowVolPct>100) err += "LowVolPct trebuie sa fie in [0,100]. ";
   if(InpSL_Mult<=0)               err += "SL_Mult trebuie sa fie >0. ";
   if(InpTP_RR<=0)                 err += "TP_RR trebuie sa fie >0. ";
   if(InpMinRR<0)                  err += "MinRR trebuie sa fie >=0. ";
   if(InpDashThrottleMs<0)         err += "DashThrottleMs trebuie sa fie >=0. ";
   if(InpMaxInitBars<0)            err += "MaxInitBars trebuie sa fie >=0. ";
   if(StringLen(err)>0)
   {
      Alert("VolRegime: parametri de intrare invalizi — ", err);
      Print("VolRegime OnInit: ", err);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpFontSize<5)
      Print("VolRegime: FontSize prea mic, va fi clampat automat la afisare (minim 9).");
   SetIndexBuffer(0, Pct, INDICATOR_DATA);
   SetIndexBuffer(1, Clr, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, Reg, INDICATOR_DATA);
   SetIndexBuffer(3, RegClr, INDICATOR_COLOR_INDEX);

   ArrayInitialize(Pct, 50.0);
   ArrayInitialize(Clr, 0);
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, InpPeriod + InpLookback);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 0, GC(InpC_Normal));
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 1, GC(InpC_Low));
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 2, GC(InpC_Elev));
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 3, GC(InpC_High));
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 4, GC(InpC_Extr));

   IndicatorSetInteger(INDICATOR_LEVELS, 3);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 0, InpLow);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 1, InpElevated);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 2, InpExtreme);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 0, GC(InpC_Low));
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 1, GC(InpC_Elev));
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 2, GC(InpC_Extr));
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 0, STYLE_DOT);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 1, STYLE_DOT);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 2, STYLE_DOT);
   atrH = iATR(_Symbol, PERIOD_CURRENT, InpPeriod);
   if(atrH == INVALID_HANDLE)
   {
      Print("VolRegime: iATR handle invalid, cod eroare ", GetLastError());
      return INIT_FAILED;
   }

   maH = iMA(_Symbol, PERIOD_CURRENT, InpMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(maH == INVALID_HANDLE)
   {
      Print("VolRegime: iMA handle invalid, cod eroare ", GetLastError());
      IndicatorRelease(atrH);
      atrH = INVALID_HANDLE;
      return INIT_FAILED;
   }

   lastReg = -1; pendReg = -1; pendCnt = 0;
   lastDashMs = 0;

   IndicatorSetString(INDICATOR_SHORTNAME, "VolRegime 4.10");
   IndicatorSetInteger(INDICATOR_DIGITS, 1);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, PF);
   ObjectDelete(0, "VR_ChartBG");
   if(atrH != INVALID_HANDLE) { IndicatorRelease(atrH); atrH = INVALID_HANDLE; }
   if(maH  != INVALID_HANDLE) { IndicatorRelease(maH);  maH  = INVALID_HANDLE; }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
{
   if(atrH == INVALID_HANDLE || maH == INVALID_HANDLE) return 0;

   int minBars = InpPeriod + InpLookback + InpMAPeriod + 15;
   if(rates_total < minBars) return 0;

   if(ArrayResize(Vol, rates_total) < 0)       return 0;
   if(ArrayResize(RegDurArr, rates_total) < 0) return 0;

   if(prev_calculated == 0)
   {
      lastReg = -1; pendReg = -1; pendCnt = 0;
      ArrayInitialize(Vol, 0.0);
      ArrayInitialize(RegDurArr, 1.0);
   }

   int start = (prev_calculated > minBars) ? prev_calculated-1 : InpPeriod+InpLookback;

   int volStart = MathMax(1, start - InpLookback - InpPeriod - 2);
   if(InpVolType == ATR)
   {
      double a[];
      ArraySetAsSeries(a, true);
      int need = rates_total - volStart;
      if(need > 0)
      {
         if(CopyBuffer(atrH, 0, 0, need, a) <= 0) return 0;
         for(int k=0; k<need; k++) Vol[rates_total-1-k] = a[k];
      }
   }
   else if(InpVolType == PARKINSON)
   {
      for(int i=volStart; i<rates_total; i++)
      {
         if(i<InpPeriod) { Vol[i]=0.0; continue; }
         double s=0; int c=0;
         for(int k=0; k<InpPeriod; k++)
         {
            int idx=i-k;
            if(high[idx]>0 && low[idx]>0 && high[idx]>=low[idx])
            {
               double hl=MathLog(high[idx]/low[idx]);
               s+=hl*hl; c++;
            }
         }
         Vol[i] = (c>0) ? MathSqrt(s/(4.0*MathLog(2.0)*InpPeriod)) : 0.0;
      }
   }
   else // HIST
   {
      for(int i=volStart; i<rates_total; i++)
      {
         if(i<InpPeriod) { Vol[i]=0.0; continue; }
         double s=0; int c=0;
         for(int k=0; k<InpPeriod; k++)
         {
            int idx=i-k;
            if(idx-1<0 || close[idx-1]<=0 || close[idx]<=0) continue;
            double r=MathLog(close[idx]/close[idx-1]);
            s+=r*r; c++;
         }
         Vol[i] = (c>0) ? MathSqrt(s/c) : 0.0;
      }
   }

   double atr=0;
   double ab[];
   ArraySetAsSeries(ab, true);
   if(CopyBuffer(atrH, 0, 0, 2, ab)>0) atr = ab[0];

   int pctStart = start;
   if(prev_calculated == 0 && InpMaxInitBars > 0 && rates_total - pctStart > InpMaxInitBars)
      pctStart = rates_total - InpMaxInitBars;

   for(int i=pctStart; i<rates_total; i++)
   {
      if(Vol[i]<=0 || !MathIsValidNumber(Vol[i]))
      {
         Pct[i] = i>0 ? Pct[i-1] : 50.0;
         Clr[i] = i>0 ? Clr[i-1] : 0;
         RegDurArr[i] = i>0 ? RegDurArr[i-1] : 1;
         if(InpShowBG) { Reg[i]=100.0; RegClr[i]=(int)Clr[i]; }
         else          { Reg[i]=EMPTY_VALUE; RegClr[i]=0; }
         continue;
      }

      int lowC=0, valid=0;
      int from = MathMax(0, i-InpLookback+1);
      for(int j=from; j<=i; j++)
      {
         if(Vol[j]<=0 || !MathIsValidNumber(Vol[j])) continue;
         valid++;
         if(Vol[j] <= Vol[i]) lowC++;
      }

      double raw = valid>0 ? 100.0*lowC/valid : 50.0;
      raw = MathMax(0.0, MathMin(100.0, raw));

      if(InpSmooth>1 && i>=InpSmooth)
      {
         double s=raw;
         int c=1;
         for(int k=1; k<InpSmooth; k++)
            if(MathIsValidNumber(Pct[i-k]) && Pct[i-k]>=0 && Pct[i-k]<=100)
            { s+=Pct[i-k]; c++; }
         Pct[i] = s/c;
      }
      else Pct[i] = raw;

      if(!MathIsValidNumber(Pct[i])) Pct[i]=50.0;

      int rawR = 0;
      if(Pct[i] <= InpLow)           rawR = 1;
      else if(Pct[i] < InpElevated)  rawR = 0;
      else if(Pct[i] < InpExtreme)   rawR = 2;
      else if(Pct[i] < 95.0)         rawR = 3;
      else                           rawR = 4;

      if(rawR == pendReg) pendCnt++;
      else { pendReg = rawR; pendCnt = 1; }

      if(pendCnt >= InpPersist)
      {
         Clr[i] = pendReg;
         RegDurArr[i] = (i>0 && Clr[i]==Clr[i-1]) ? RegDurArr[i-1]+1 : 1;
      }
      else
      {
         Clr[i] = i>0 ? Clr[i-1] : 0;
         RegDurArr[i] = i>0 ? RegDurArr[i-1] : 1;
      }

      if(InpShowBG) { Reg[i]=100.0; RegClr[i]=(int)Clr[i]; }
      else          { Reg[i]=EMPTY_VALUE; RegClr[i]=0; }
   }

   bool newBar = (prev_calculated != rates_total);
   uint nowMs  = GetTickCount();
   bool due    = (nowMs - lastDashMs) >= (uint)MathMax(0, InpDashThrottleMs);
   if(rates_total > minBars && (newBar || due))
   {
      lastDashMs = nowMs;
      double pct = Pct[rates_total-1];
      if(!MathIsValidNumber(pct) || pct<0 || pct>100) pct=50.0;
      int regime = (int)Clr[rates_total-1];
      int dur = (int)RegDurArr[rates_total-1];
      if(regime<0 || regime>4) regime=0;

      double z = CalcZ(Vol, rates_total);
      double vPct = InpVolFilter ? CalcVolPct(tick_volume, rates_total) : 50.0;
      bool lowVol = InpVolFilter && vPct <= InpLowVolPct;

      string mtf = "Off";
      bool mtfOk = true;
      if(InpMTF)
      {
         ENUM_TIMEFRAMES mtfTF = GetMTFTimeframe();
         if(mtfTF == Period())
         {
            mtfOk = true;
            mtf   = "N/A (top TF)";
         }
         else
         {
            mtfOk = CheckMTF(regime, mtfTF);
            mtf   = TFName(mtfTF) + (mtfOk ? " OK" : " Conflict");
         }
      }

      double ma=0;
      double mb[];
      ArraySetAsSeries(mb, true);
      if(maH != INVALID_HANDLE && CopyBuffer(maH, 0, 0, 2, mb)>0) ma = mb[0];

      double price = close[rates_total-1];
      string sig = "NEUTRAL";
      color sigC = GC(C_Gold);
      int dir = 0;

      int trendDirP = 0;
      if(price>ma) trendDirP=1; else if(price<ma) trendDirP=-1;
      double trendStrengthATR = (atr>0) ? MathAbs(price-ma)/atr : 0.0;

      int momLB = 5;
      double momentumATR = 0.0;
      if(atr>0 && rates_total-1-momLB >= 0)
         momentumATR = (close[rates_total-1]-close[rates_total-1-momLB])/atr;

      bool volOk = !InpVolFilter || !lowVol;

      if(regime==1 && mtfOk && volOk)
      {
         if(price > ma)      { dir=1;  sig="BUY";  sigC=GC(InpC_Buy);  }
         else if(price < ma) { dir=-1; sig="SELL"; sigC=GC(InpC_Sell); }
         else                { sig="NEUTRAL (Flat)"; sigC=GC(C_Gold); }
      }
      else if(regime==1 && !volOk)  { sig="NEUTRAL (Low Volume)"; sigC=GC(C_Gold); }
      else if(regime==1 && !mtfOk)  { sig="NEUTRAL (MTF Conflict)"; sigC=GC(C_Gold); }
      else if(regime>=3)            { sig="NEUTRAL (High Risk)"; sigC=GC(C_Gold); }
      else                          { sig="NEUTRAL"; sigC=GC(C_Gold); }

      double sl=0, tp=0, rr=0;
      string rrS = "";
      if(atr>0 && dir!=0)
      {
         double risk = atr * InpSL_Mult;
         if(dir==1){ sl=price-risk; tp=price+risk*InpTP_RR; }
         else      { sl=price+risk; tp=price-risk*InpTP_RR; }
         rr = InpTP_RR;
         rrS = rr>=InpMinRR ? "OK" : "Low";
      }

      SProbScore prob;
      CalcProbabilityScore(regime, InpMTF, mtfOk, vPct, trendDirP, trendStrengthATR, momentumATR, prob);

      if(InpChartBG) ChartBG(regime>=3);
      if(InpShowDash)
         Dash(pct, regime, dur, z, mtf, lowVol, vPct, sig, sigC, sl, tp, rr, rrS, prob);

      if(InpShowDash || InpChartBG)
         ChartRedraw(0);

      if(newBar && lastReg>=0 && regime!=lastReg)
      {
         if(InpAlertChange) Alert(_Symbol," Regime: ",RName(regime));
         if(InpAlertLow && regime==1) Alert(_Symbol," LOW VOL");
         if(InpAlertExtr && regime>=3) Alert(_Symbol," EXTREME VOL");
      }
      lastReg = regime;
   }

   return rates_total;
}

//+------------------------------------------------------------------+
double CalcZ(const double &v[], int n)
{
   int lb = MathMin(InpLookback, n-1);
   if(lb<10) return 0;
   double s=0, s2=0;
   int c=0;
   for(int i=n-lb; i<n; i++)
   {
      if(v[i]<=0 || !MathIsValidNumber(v[i])) continue;
      s+=v[i]; s2+=v[i]*v[i];
      c++;
   }
   if(c<5) return 0;
   double m=s/c, var=s2/c-m*m;
   if(var<=0) return 0;
   double std=MathSqrt(var);
   return std>0 ? (v[n-1]-m)/std : 0;
}

double CalcVolPct(const long &tv[], int n)
{
   int lb = MathMin(InpVolLookback, n-1);
   if(lb<10) return 50.0;
   long cur = tv[n-1];
   int low=0, val=0;
   for(int i=n-lb; i<n; i++)
   {
      if(tv[i]<=0) continue;
      val++; if(tv[i]<=cur) low++;
   }
   return val>0 ? 100.0*low/val : 50.0;
}

ENUM_TIMEFRAMES GetMTFTimeframe()
{
   ENUM_TIMEFRAMES cur = (ENUM_TIMEFRAMES)Period();
   ENUM_TIMEFRAMES want = InpMTFPeriod;
   if(want <= cur)
   {
      if(cur < PERIOD_H1)       want = PERIOD_H1;
      else if(cur < PERIOD_H4)  want = PERIOD_H4;
      else if(cur < PERIOD_D1)  want = PERIOD_D1;
      else if(cur < PERIOD_W1)  want = PERIOD_W1;
      else if(cur < PERIOD_MN1) want = PERIOD_MN1;
      else                      want = cur;
   }
   return want;
}

string TFName(ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
}

bool CheckMTF(int regime, ENUM_TIMEFRAMES tf)
{
   if(tf == Period()) return true;

   double h[], l[];
   ArraySetAsSeries(h,true); ArraySetAsSeries(l,true);
   int need = InpLookback + InpPeriod + 5;
   if(CopyHigh(_Symbol, tf, 0, need, h)<need) return true;
   if(CopyLow(_Symbol, tf, 0, need, l)<need) return true;

   double sum=0; int cnt=0;
   for(int i=1; i<=InpPeriod; i++)
      if(h[i]>0 && l[i]>0)
      {
         double hl=MathLog(h[i]/l[i]);
         sum+=hl*hl; cnt++;
      }
   if(cnt<5) return true;
   double cur = MathSqrt(sum/(4.0*MathLog(2.0)*cnt));

   int low=0, val=0;
   for(int i=0; i<InpLookback; i++)
   {
      double s=0; int c=0;
      for(int k=0; k<InpPeriod && i+k<need; k++)
         if(h[i+k]>0 && l[i+k]>0)
         {
            double hl=MathLog(h[i+k]/l[i+k]);
            s+=hl*hl; c++;
         }
      if(c>0)
      {
         double v=MathSqrt(s/(4.0*MathLog(2.0)*c));
         val++; if(v<=cur) low++;
      }
   }
   double pct = val>0 ? 100.0*low/val : 50.0;
   if(regime==1 && pct>InpElevated) return false;
   if(regime>=3 && pct<InpLow) return false;
   return true;
}

void ChartBG(bool on)
{
   if(on)
   {
      if(ObjectFind(0,"VR_ChartBG")<0)
      {
         ObjectCreate(0,"VR_ChartBG",OBJ_RECTANGLE_LABEL,0,0,0);
         ObjectSetInteger(0,"VR_ChartBG",OBJPROP_XDISTANCE,0);
         ObjectSetInteger(0,"VR_ChartBG",OBJPROP_YDISTANCE,0);
         ObjectSetInteger(0,"VR_ChartBG",OBJPROP_BACK,true);
         ObjectSetInteger(0,"VR_ChartBG",OBJPROP_SELECTABLE,false);
      }
      ObjectSetInteger(0,"VR_ChartBG",OBJPROP_XSIZE,(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS));
      ObjectSetInteger(0,"VR_ChartBG",OBJPROP_YSIZE,(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS));
      ObjectSetInteger(0,"VR_ChartBG",OBJPROP_BGCOLOR,GC(InpC_ChartBG));
   }
   else ObjectDelete(0,"VR_ChartBG");
}

string RName(int r)
{
   if(r==1) return "LOW VOL";
   if(r==2) return "ELEVATED";
   if(r==3) return "HIGH VOL";
   if(r==4) return "EXTREME";
   return "NORMAL";
}

string ProbBar(double pct)
{
   int filled = (int)MathRound(pct/10.0);
   if(filled<0) filled=0;
   if(filled>10) filled=10;
   string bar="";
   for(int i=0;i<filled;i++)  bar += "█";
   for(int i=filled;i<10;i++) bar += "░";
   return bar;
}

void CalcProbabilityScore(int regime, bool mtfEnabled, bool mtfOk, double vPct,
                           int trendDir, double trendStrengthATR, double momentumATR,
                           SProbScore &p)
{
   double score = 50.0;
   score += trendDir * MathMin(MathAbs(trendStrengthATR)*15.0, 20.0);
   double momDir = (momentumATR>0) ? 1.0 : (momentumATR<0 ? -1.0 : 0.0);
   score += momDir * MathMin(MathAbs(momentumATR)*15.0, 15.0);
   score += (vPct-50.0)*0.2;
   if(mtfEnabled) score += mtfOk ? 8.0 : -8.0;
   switch(regime)
   {
      case 1: score += 10.0; break;
      case 0: score += 5.0;  break;
      case 2: score += 0.0;  break;
      case 3: score -= 8.0;  break;
      case 4: score -= 15.0; break;
   }

   score = MathMax(0.0, MathMin(100.0, score));
   if(MathAbs(score-50.0) < 3.0)
   {
      p.dir = "NEUTRAL";
      p.probability = score;
      p.dirC = GC(InpC_Warn);
   }
   else if(score > 50.0)
   {
      p.dir = "BUY";
      p.probability = score;
      p.dirC = GC(InpC_Buy);
   }
   else
   {
      p.dir = "SELL";
      p.probability = 100.0 - score;
      p.dirC = GC(InpC_Sell);
   }

   if(p.probability>=85)      p.grade="AAAA";
   else if(p.probability>=75) p.grade="AAA";
   else if(p.probability>=65) p.grade="AA";
   else if(p.probability>=55) p.grade="A";
   else if(p.probability>=45) p.grade="B";
   else                       p.grade="C";

   if(p.probability>=80)      p.confidence="HIGH";
   else if(p.probability>=65) p.confidence="MEDIUM";
   else                       p.confidence="LOW";
   p.bar = ProbBar(p.probability);

   if(trendDir>0)      { p.trendLbl="BULLISH"; p.trendC=GC(InpC_Buy); }
   else if(trendDir<0) { p.trendLbl="BEARISH"; p.trendC=GC(InpC_Sell); }
   else                { p.trendLbl="FLAT";    p.trendC=GC(InpC_Muted); }

   double am = MathAbs(momentumATR);
   if(am>=1.0)      p.momLbl="STRONG";
   else if(am>=0.4) p.momLbl="MODERATE";
   else             p.momLbl="WEAK";
   p.momC = (momDir>0) ? GC(InpC_Buy) : (momDir<0 ? GC(InpC_Sell) : GC(InpC_Muted));

   if(regime<=1)      { p.riskLbl="LOW";    p.riskC=GC(InpC_Buy); }
   else if(regime==2) { p.riskLbl="MEDIUM"; p.riskC=GC(InpC_Warn); }
   else               { p.riskLbl="HIGH";   p.riskC=GC(InpC_Extr); }

   if(vPct>=70)      { p.volLbl="HIGH";   p.volC=GC(InpC_Buy); }
   else if(vPct>=40) { p.volLbl="MEDIUM"; p.volC=GC(InpC_Muted); }
   else              { p.volLbl="LOW";    p.volC=GC(InpC_Warn); }
}

void Dash(double pct, int regime, int dur, double z, string mtf,
          bool lowVol, double vPct, string sig, color sigC, double sl, double tp, double rr, string rrS,
          const SProbScore &p)
{
   int fs = MathMax(9, InpFontSize);
   int lh = fs + 7;
   int pad = 9;
   int th = fs + 5;
   int lines = 9;
   if(sl>0) lines++;
   if(InpMTF) lines++;
   if(InpVolFilter) lines++;

   int w = (int)(fs * 30);
   if(w<300) w=300;
   if(w>500) w=500;
   int h = pad + th + lines*lh + pad + 4;

   Rect(PF+"BG", 10, 16, w, h, GC(InpC_BG));
   int y = 16 + pad;
   int x = 10 + pad;
   Lbl(PF+"T", x, y, "VOL REGIME 4.00", GC(InpC_Title), fs, true); y+=th;
   Lbl(PF+"PB1", x, y, "Probability "+p.dir+"  "+DoubleToString(p.probability,0)+"%", p.dirC, fs, true); y+=lh;
   Lbl(PF+"PB2", x, y, p.bar, p.dirC, fs, true); y+=lh;
   Lbl(PF+"PB3", x, y, "Grade: "+p.grade+"   Confidence: "+p.confidence, GC(InpC_Text), fs, false); y+=lh;

   Lbl(PF+"P", x, y, "Pct "+DoubleToString(pct,1)+"%  |  Z "+DoubleToString(z,2), GC(InpC_Text), fs, false); y+=lh;

   color rc = GC(InpC_Normal);
   if(regime==1) rc=GC(InpC_Low);
   else if(regime==2) rc=GC(InpC_Elev);
   else if(regime==3) rc=GC(InpC_High);
   else if(regime==4) rc=GC(InpC_Extr);
   Lbl(PF+"R", x, y, "Regime: "+RName(regime)+"  ("+IntegerToString(dur)+" bars)", rc, fs, true); y+=lh;
   if(InpVolFilter)
   {
      Lbl(PF+"V", x, y, "Volume: "+p.volLbl+"  ("+DoubleToString(vPct,0)+"%)", p.volC, fs, false); y+=lh;
   }

   if(InpMTF)
   {
      color mc = (StringFind(mtf,"OK")>=0 || mtf=="Off") ? GC(InpC_Low) : GC(InpC_Warn);
      Lbl(PF+"M", x, y, "MTF: "+mtf, mc, fs, false); y+=lh;
   }

   Lbl(PF+"TR", x, y, "Trend: "+p.trendLbl, p.trendC, fs, false); y+=lh;
   Lbl(PF+"MO", x, y, "Momentum: "+p.momLbl, p.momC, fs, false); y+=lh;
   Lbl(PF+"RK", x, y, "Risk: "+p.riskLbl, p.riskC, fs, false); y+=lh;

   Lbl(PF+"S", x, y, "Signal: "+sig, sigC, fs, true); y+=lh;
   if(sl>0)
   {
      Lbl(PF+"SL", x, y, "SL "+DoubleToString(sl,_Digits)+"  TP "+DoubleToString(tp,_Digits)+
          "  R:R "+DoubleToString(rr,1)+" ("+rrS+")",
          rr>=InpMinRR ? GC(InpC_Buy) : GC(InpC_Warn), fs, false);
      y+=lh;
   }
   else ObjectDelete(0, PF+"SL");
   
   ObjectDelete(0, PF+"X");
}

void Rect(string n, int x, int y, int w, int h, color bg)
{
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
}

void Lbl(string n, int x, int y, string t, color c, int s, bool bold)
{
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetString(0,n,OBJPROP_TEXT,t);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,s);
   ObjectSetString(0,n,OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
}