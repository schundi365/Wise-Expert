//+------------------------------------------------------------------+
//| GridHedge.mq5   v3.00                                            |
//| JNS-style grid/hedging EA. Dual BUY/SELL grids, per-level         |
//| parameters, code-managed exits, full interactive dashboard.       |
//|                                                                  |
//| IMPORTANT: the control meanings below are MY interpretation of a  |
//| sensible grid EA (from the JNS panel's abbreviations). They are   |
//| NOT reverse-engineered from the JNS binary (that is compiled,     |
//| packed, and a paid product). If your JNS does something different |
//| for a given control, tell me and I'll adjust that behaviour.      |
//|                                                                  |
//| Exit model is grounded in the real trade report (naked entries,   |
//| code profit-close ~70pt, keep-top-2 hedge, unstopped losers).     |
//| The SAFETY floor (max levels / floating-loss / equity stop) is    |
//| the only thing bounding the martingale tail - keep it on.         |
//+------------------------------------------------------------------+
#property copyright "Wise Trader project - GridHedge"
#property version   "3.00"
#property description "JNS-style grid EA: per-level grid table, ST/PU/CL/SY/REP controls, Start/Target/SL basket, live position table, safety floor."

#include <Trade/Trade.mqh>

#define LVLS 4     // grid levels per side: index 0=Gap2, 1=Gap3, 2=Gap4, 3=ProS

//--- inputs (seed values; panel edits them live) --------------------
input group "Base (seeds level 1 + defaults)"
input double InpLot          = 0.10;    // Base lot per position
input int    InpGapPoints    = 500;     // Base gap between levels, POINTS (500 = $5.00 XAUUSD)
input int    InpTpPoints     = 700;     // Base per-position profit-close, POINTS
input int    InpLockPoints   = 700;     // Base lock-and-book distance, POINTS
input bool   InpTradeBuy     = true;    // Enable BUY side at start
input bool   InpTradeSell    = true;    // Enable SELL side at start

input group "Management (Prot / B+S)"
input int    InpProtPoints   = 300;     // Prot: arm break-even once position +this pts (0 = off)
input int    InpBSStepPoints = 50;      // B+S: trailing step after break-even, points (0 = static BE)
input int    InpBeOffsetPoints = 10;    // Break-even offset beyond entry, points

input group "Basket (Start / Target / SL) - JNS Target = book winners keep top-2"
input double InpBuyTarget    = 0.0;     // BUY target price: book winners, keep top-N (0 = off)
input double InpSellTarget   = 0.0;     // SELL target price: book winners, keep top-N (0 = off)
input int    InpKeepHedge    = 2;       // How many highest-profit positions to keep on Target
input double InpSideSL       = 0.0;     // Basket SL: close a side if its floating loss <= -this (0 = off)

input group "Safety (defaults ON - the floor)"
input int    InpMaxLevels        = 8;     // Max open positions PER SIDE (0 = unlimited - DANGEROUS)
input double InpMaxFloatingLoss  = 800.0; // Close ALL if combined floating P/L <= -this (0 = off)
input double InpEquityStopPct    = 20.0;  // Close ALL + halt if equity drops this % below start (0 = off)
input double InpBasketTP         = 0.0;   // Close ALL when combined floating P/L >= this (0 = off)
input bool   InpCloseAllOnStop   = true;  // On a safety trip, flatten every position for this magic

input group "Engine"
input long   InpMagic        = 26023332;  // Magic number
input int    InpSlippage     = 30;         // Max deviation, points
input bool   InpStartRunning = true;       // Master START on attach
input bool   InpShowPanel    = true;       // Draw dashboard
input bool   InpEnableLog    = true;       // Log to Experts tab

//--- per-level parameters (Gap2/3/4/ProS). Level 1 uses base inputs.
struct SLevel { int gap; double lot; int tp; int lock; bool on; };

//--- per-side runtime state
struct SSide
  {
   bool   enabled;   // ST/PU: new entries allowed
   double target;    // basket price target (book winners keep top-N)
   SLevel lv[LVLS];  // Gap2..ProS
  };

//--- global runtime
struct SLive
  {
   double lot; int gap; int tp; int lock;  // base level-1 params
   int    prot; int bs;                     // management
   bool   running;                          // master
   SSide  buy;
   SSide  sell;
  };
SLive g;

//--- state
CTrade   m_trade;
string   m_sym;
double   m_point;
int      m_digits;
double   m_start_equity = 0.0;
bool     m_halted = false;
uint     m_last_draw = 0;

void Log(const string s){ if(InpEnableLog) Print("[GridHedge] ", s); }
double Ask(){ return SymbolInfoDouble(m_sym,SYMBOL_ASK); }
double Bid(){ return SymbolInfoDouble(m_sym,SYMBOL_BID); }
double Nz(double p){ return NormalizeDouble(p,m_digits); }

#define PFX "GH_"
void PanelCreate(); void PanelUpdate(); void PanelDestroy();

//====================================================================
//  INIT
//====================================================================
void SeedSide(SSide &s, bool en, double tgt)
  {
   s.enabled = en; s.target = tgt;
   //--- default per-level params derived from base; ProS = big TP scalp
   for(int i=0;i<LVLS;i++)
     {
      s.lv[i].gap  = g.gap;
      s.lv[i].lot  = g.lot;
      s.lv[i].tp   = g.tp;
      s.lv[i].lock = g.lock;
      s.lv[i].on   = true;
     }
   //--- ProS (index 3): a wide profit-scalp target by default
   s.lv[LVLS-1].tp = g.tp * 5;
  }

int OnInit()
  {
   m_sym=_Symbol; m_point=SymbolInfoDouble(m_sym,SYMBOL_POINT);
   m_digits=(int)SymbolInfoInteger(m_sym,SYMBOL_DIGITS);
   if(InpLot<=0||InpGapPoints<=0||InpTpPoints<=0)
     { Print("[GridHedge] bad inputs"); return INIT_PARAMETERS_INCORRECT; }
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("[GridHedge] WARNING: not a hedging account - buy/sell will net off.");

   g.lot=InpLot; g.gap=InpGapPoints; g.tp=InpTpPoints; g.lock=InpLockPoints;
   g.prot=InpProtPoints; g.bs=InpBSStepPoints; g.running=InpStartRunning;
   SeedSide(g.buy,  InpTradeBuy,  InpBuyTarget);
   SeedSide(g.sell, InpTradeSell, InpSellTarget);

   m_trade.SetExpertMagicNumber(InpMagic);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFillingBySymbol(m_sym);
   m_start_equity=AccountInfoDouble(ACCOUNT_EQUITY); m_halted=false;

   if(InpShowPanel) PanelCreate();
   ChartRedraw(0);
   Log(StringFormat("init v3.00 lot=%.2f gap=%d tp=%d lock=%d prot=%d bs=%d run=%s",
        g.lot,g.gap,g.tp,g.lock,g.prot,g.bs,g.running?"on":"off"));
   return INIT_SUCCEEDED;
  }
void OnDeinit(const int r){ PanelDestroy(); ChartRedraw(0); }

//====================================================================
//  POSITION HELPERS
//====================================================================
int SideCount(const ENUM_POSITION_TYPE side)
  {
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==side)n++; }
   return n;
  }
double LastEntryPrice(const ENUM_POSITION_TYPE side,bool &found)
  {
   found=false; double res=0; datetime nw=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=side)continue;
       datetime tt=(datetime)PositionGetInteger(POSITION_TIME);
       if(tt>=nw){nw=tt;res=PositionGetDouble(POSITION_PRICE_OPEN);found=true;} }
   return res;
  }
double SideFloating(const ENUM_POSITION_TYPE side)
  {
   double tot=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=side)continue;
       tot+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP); }
   return tot;
  }
double BasketFloating(){ return SideFloating(POSITION_TYPE_BUY)+SideFloating(POSITION_TYPE_SELL); }

//--- which level params apply to the Nth open position on a side (clamped)
void LevelFor(const ENUM_POSITION_TYPE side,const int count,SLevel &out)
  {
   SSide s = (side==POSITION_TYPE_BUY)? g.buy : g.sell;
   //--- position 1 uses base; positions 2.. map to lv[0..]; clamp to ProS
   if(count<=1){ out.gap=g.gap; out.lot=g.lot; out.tp=g.tp; out.lock=g.lock; out.on=true; return; }
   int idx = count-2; if(idx>=LVLS) idx=LVLS-1;
   out = s.lv[idx];
  }

//====================================================================
//  ORDERS
//====================================================================
bool OpenLevel(const ENUM_POSITION_TYPE side,const int level,const double lot)
  {
   string cmt=StringFormat("P%d",level); bool ok;
   if(side==POSITION_TYPE_BUY) ok=m_trade.Buy(lot,m_sym,0,0,0,cmt);
   else                        ok=m_trade.Sell(lot,m_sym,0,0,0,cmt);
   Log(StringFormat("%s %s lot=%.2f: %s rc=%u",side==POSITION_TYPE_BUY?"BUY":"SELL",cmt,lot,
        ok?"opened":"FAILED",m_trade.ResultRetcode()));
   return ok;
  }
void CloseSide(const ENUM_POSITION_TYPE side,const string reason)
  {
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=side)continue;
       if(m_trade.PositionClose(t))n++; }
   if(n>0) Log(StringFormat("close %s x%d: %s",side==POSITION_TYPE_BUY?"BUY":"SELL",n,reason));
  }
void CloseAll(const string reason){ CloseSide(POSITION_TYPE_BUY,reason); CloseSide(POSITION_TYPE_SELL,reason); Log("CLOSE ALL: "+reason); }

//--- Target: book profitable positions on a side but keep top-N by profit
void BookPositivesKeepTop(const ENUM_POSITION_TYPE side,const int keep,const string reason)
  {
   ulong tk[]; double pf[]; int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=side)continue;
       double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
       if(p<=0)continue;
       ArrayResize(tk,n+1);ArrayResize(pf,n+1);tk[n]=t;pf[n]=p;n++; }
   if(n<=keep)return;
   for(int a=0;a<n-1;a++)for(int b=a+1;b<n;b++)
      if(pf[b]>pf[a]){double x=pf[a];pf[a]=pf[b];pf[b]=x;ulong y=tk[a];tk[a]=tk[b];tk[b]=y;}
   int closed=0; for(int i=keep;i<n;i++) if(m_trade.PositionClose(tk[i]))closed++;
   if(closed>0) Log(StringFormat("%s TARGET %s: booked %d, kept top %d",side==POSITION_TYPE_BUY?"BUY":"SELL",reason,closed,keep));
  }

//====================================================================
//  MANAGEMENT: profit-close, lock-book, Prot(BE) + B+S(trail)
//====================================================================
void ManagePositions()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i); if(t==0)continue;
      if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool lng=(type==POSITION_TYPE_BUY);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double cur= lng?Bid():Ask();
      double ppt=(lng?(cur-entry):(entry-cur))/m_point;

      //--- profit close (code TP, per base params - simplification: base tp)
      if(g.tp>0 && ppt>=g.tp){ if(m_trade.PositionClose(t))Log(StringFormat("#%I64u PROFIT +%.0f",t,ppt)); continue; }
      //--- lock & book (only if above tp)
      if(g.lock>0 && g.lock!=g.tp && ppt>=g.lock){ if(m_trade.PositionClose(t))Log(StringFormat("#%I64u LOCK +%.0f",t,ppt)); continue; }

      //--- Prot: arm break-even; B+S: trail the stop in steps once armed
      if(g.prot>0 && ppt>=g.prot)
        {
         double be = lng? entry+InpBeOffsetPoints*m_point : entry-InpBeOffsetPoints*m_point;
         double want = be;
         if(g.bs>0)  // trail: keep stop g.bs points behind current, but never worse than BE
           {
            double trail = lng? cur-g.bs*m_point : cur+g.bs*m_point;
            want = lng? MathMax(be,trail) : MathMin(be,trail);
           }
         want=Nz(want);
         bool need = lng? (sl<want-m_point) : (sl==0.0 || sl>want+m_point);
         if(need && m_trade.PositionModify(t,want,0.0))
            Log(StringFormat("#%I64u Prot/B+S SL->%.*f (+%.0f)",t,m_digits,want,ppt));
        }
     }
  }

//====================================================================
//  SAFETY
//====================================================================
bool SafetyCheck()
  {
   if(m_halted)return true;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY), bk=BasketFloating();
   if(InpBasketTP>0 && bk>=InpBasketTP){ CloseAll(StringFormat("basket TP %.2f",bk)); return false; }
   if(InpMaxFloatingLoss>0 && bk<=-InpMaxFloatingLoss)
     { if(InpCloseAllOnStop)CloseAll(StringFormat("MAX FLOAT LOSS %.2f",bk)); m_halted=true; g.running=false;
       Log("HALTED float-loss. START to resume."); return true; }
   if(InpEquityStopPct>0 && m_start_equity>0)
     { double dd=(m_start_equity-eq)/m_start_equity*100.0;
       if(dd>=InpEquityStopPct){ if(InpCloseAllOnStop)CloseAll(StringFormat("EQ STOP %.2f%%",dd)); m_halted=true; g.running=false;
         Log("HALTED equity. START to resume."); return true; } }
   return false;
  }

//--- basket SL per side + Target price booking
void BasketChecks()
  {
   if(InpSideSL>0)
     { if(SideCount(POSITION_TYPE_BUY)>0  && SideFloating(POSITION_TYPE_BUY) <=-InpSideSL) CloseSide(POSITION_TYPE_BUY,"side SL");
       if(SideCount(POSITION_TYPE_SELL)>0 && SideFloating(POSITION_TYPE_SELL)<=-InpSideSL) CloseSide(POSITION_TYPE_SELL,"side SL"); }
   if(g.buy.target>0  && SideCount(POSITION_TYPE_BUY) >InpKeepHedge && Bid()>=g.buy.target)
      BookPositivesKeepTop(POSITION_TYPE_BUY, InpKeepHedge, StringFormat("bid>=%.*f",m_digits,g.buy.target));
   if(g.sell.target>0 && SideCount(POSITION_TYPE_SELL)>InpKeepHedge && Ask()<=g.sell.target)
      BookPositivesKeepTop(POSITION_TYPE_SELL,InpKeepHedge, StringFormat("ask<=%.*f",m_digits,g.sell.target));
  }

//====================================================================
//  GRID (per-level gap/lot)
//====================================================================
void ManageSide(const ENUM_POSITION_TYPE side,const SSide &s)
  {
   if(!s.enabled) return;
   int count=SideCount(side);
   if(InpMaxLevels>0 && count>=InpMaxLevels) return;
   if(count==0){ OpenLevel(side,1,g.lot); return; }

   //--- next level's params
   SLevel nx; LevelFor(side,count+1,nx);
   if(!nx.on) return;
   bool found=false; double last=LastEntryPrice(side,found); if(!found)return;
   double gap=nx.gap*m_point;
   bool add=false;
   if(side==POSITION_TYPE_BUY  && Ask()<=last-gap) add=true;
   if(side==POSITION_TYPE_SELL && Bid()>=last+gap) add=true;
   if(add) OpenLevel(side,count+1,nx.lot);
  }

void OnTick()
  {
   if(SafetyCheck()){ PanelUpdate(); return; }
   BasketChecks();
   ManagePositions();
   if(g.running)
     { ManageSide(POSITION_TYPE_BUY,  g.buy);
       ManageSide(POSITION_TYPE_SELL, g.sell); }
   uint now=GetTickCount(); if(now-m_last_draw>=250){ m_last_draw=now; PanelUpdate(); }
  }

//====================================================================
//  DASHBOARD (v3) - full JNS-style layout
//  Control meanings are INTERPRETED (see header). Buttons per side:
//   ST=enable entries  PU=pause entries  CL=close side
//   SY=resync panel     REP=log side report
//  Fields: Lot / Prot / Lock / B+S ; basket: Start(disp) / Target / SL
//  Grid table: Gap2/3/4/ProS x (Gap | Lot | Profit | Lock | ON)
//====================================================================
#define GH_X    8      // panel left edge
#define GH_Y    22     // panel top edge
#define GH_W    340    // side-panel width (wide enough that all columns fit inside)
#define GH_PAD  12     // inner left/right padding inside a panel
#define GH_GAP  14     // gap between the two side panels
#define GH_FS   8      // base font size
#define GH_RH   22     // row pitch (field rows)
#define GH_LRH  20     // per-level table row pitch

bool g_min = false;    // dashboard minimized state

color CBUYBG=C'12,28,54', CSELLBG=C'54,14,18', CHBUY=C'46,120,220', CHSELL=C'210,60,66';
color CFLD=C'22,26,34', CTXT=C'230,232,238', CMUTE=C'150,160,175';
color CON=C'0,150,70', COFF=C'120,40,44', CBTN=C'40,52,70', CGOLD=C'214,175,55';

void oRect(string n,int x,int y,int w,int h,color bg,color bd)
  { if(ObjectFind(0,n)<0)ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
    ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
    ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
    ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
    ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
    ObjectSetInteger(0,n,OBJPROP_COLOR,bd);ObjectSetInteger(0,n,OBJPROP_BACK,false);
    ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,n,OBJPROP_HIDDEN,true); }
void oLbl(string n,int x,int y,string t,color c,int fs=GH_FS,bool b=false)
  { if(ObjectFind(0,n)<0)ObjectCreate(0,n,OBJ_LABEL,0,0,0);
    ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
    ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
    ObjectSetString(0,n,OBJPROP_TEXT,t);ObjectSetString(0,n,OBJPROP_FONT,b?"Arial Bold":"Arial");
    ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);ObjectSetInteger(0,n,OBJPROP_COLOR,c);
    ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,n,OBJPROP_HIDDEN,true); }
void oEdit(string n,int x,int y,int w,int h,string t)
  { if(ObjectFind(0,n)<0)ObjectCreate(0,n,OBJ_EDIT,0,0,0);
    ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
    ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
    ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
    ObjectSetString(0,n,OBJPROP_TEXT,t);ObjectSetInteger(0,n,OBJPROP_FONTSIZE,GH_FS);
    ObjectSetInteger(0,n,OBJPROP_COLOR,CTXT);ObjectSetInteger(0,n,OBJPROP_BGCOLOR,CFLD);
    ObjectSetInteger(0,n,OBJPROP_ALIGN,ALIGN_CENTER);ObjectSetInteger(0,n,OBJPROP_READONLY,false);
    ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,n,OBJPROP_HIDDEN,true); }
void oBtn(string n,int x,int y,int w,int h,string t,color bg)
  { if(ObjectFind(0,n)<0)ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
    ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
    ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
    ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
    ObjectSetString(0,n,OBJPROP_TEXT,t);ObjectSetString(0,n,OBJPROP_FONT,"Arial Bold");
    ObjectSetInteger(0,n,OBJPROP_FONTSIZE,GH_FS);ObjectSetInteger(0,n,OBJPROP_COLOR,CTXT);
    ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,CGOLD);
    ObjectSetInteger(0,n,OBJPROP_STATE,false);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
    ObjectSetInteger(0,n,OBJPROP_HIDDEN,true); }

string LvName(int i){ return (i==0?"Gap2":i==1?"Gap3":i==2?"Gap4":"ProS"); }

//--- build one side; k = "b" or "s"; returns bottom Y used.
//--- All columns are computed from GH_W with fixed gutters so NOTHING
//--- overflows the panel (usable inner width = GH_W - 2*GH_PAD = 316px).
int BuildSide(int bx,string side,string k,color hc,color bg,const SSide &s)
  {
   const int L = bx + GH_PAD;              // inner left
   const int R = bx + GH_W - GH_PAD;       // inner right
   int y = GH_Y;
   int H = 26 + GH_RH + GH_RH*2 + 18 + (LVLS)*GH_LRH + 20 + GH_RH + GH_RH + 14;
   oRect(PFX+k+"bg",bx,y,GH_W,H,bg,hc);
   oLbl(PFX+k+"hd",L,y+5,side+" - GridHedge",hc,GH_FS+1,true); y+=26;

   //--- button row: ST PU CL SY RE  (5 buttons across the inner width)
   int bgap=6, bw=(316 - 4*bgap)/5;        // equal-width buttons that fit exactly
   for(int bidx=0;bidx<5;bidx++)
     {
      int bxp = L + bidx*(bw+bgap);
      string nm[5]={"ST","PU","CL","SY","REP"}; string tx[5]={"ST","PU","CL","SY","RE"};
      color  bc = (bidx==0)?(s.enabled?CON:CBTN):(bidx==2?COFF:CBTN);
      oBtn(PFX+k+nm[bidx], bxp, y, bw,18, tx[bidx], bc);
     }
   y += GH_RH+4;

   //--- field rows: 3 columns evenly across the inner width
   int colw=316/3, ew=52;
   int fc0=L, fc1=L+colw, fc2=L+2*colw;
   oLbl (PFX+k+"lLot",fc0,   y+3,"Lot", CMUTE); oEdit(PFX+k+"eLot",fc0+36, y, ew,17, DoubleToString(g.lot,2));
   oLbl (PFX+k+"lPrt",fc1,   y+3,"Prot",CMUTE); oEdit(PFX+k+"ePrt",fc1+36, y, ew,17, IntegerToString(g.prot));
   oLbl (PFX+k+"lLk", fc2,   y+3,"Lock",CMUTE); oEdit(PFX+k+"eLk", fc2+36, y, ew,17, IntegerToString(g.lock));
   y += GH_RH;
   oLbl (PFX+k+"lBS", fc0,   y+3,"B+S", CMUTE); oEdit(PFX+k+"eBS", fc0+36, y, ew,17, IntegerToString(g.bs));
   oLbl (PFX+k+"lTgt",fc1,   y+3,"Tgt", CMUTE); oEdit(PFX+k+"eTgt",fc1+36, y, ew+14,17, DoubleToString(s.target,2));
   oLbl (PFX+k+"lSL", fc2,   y+3,"SL",  CMUTE);
   y += GH_RH+4;

   //--- grid table: 6 columns fitted inside the inner width.
   //--- widths: Lv 40 | Gap 52 | Lot 52 | Prof 52 | Lock 48 | ON 44  + gutters
   int gcnt=6, gg=4;
   int wLv=38, wGap=52, wLot=52, wProf=50, wLock=46, wOn=44;
   int xLv=L, xGap=xLv+wLv+gg, xLot=xGap+wGap+gg, xProf=xLot+wLot+gg, xLock=xProf+wProf+gg, xOn=xLock+wLock+gg;
   oLbl(PFX+k+"tv",xLv,  y,"Lv",  CMUTE); oLbl(PFX+k+"tg",xGap, y,"Gap", CMUTE);
   oLbl(PFX+k+"tl",xLot, y,"Lot", CMUTE); oLbl(PFX+k+"tp",xProf,y,"Prof",CMUTE);
   oLbl(PFX+k+"tk",xLock,y,"Lock",CMUTE); oLbl(PFX+k+"to",xOn,  y,"ON",  CMUTE);
   y += 18;
   for(int i=0;i<LVLS;i++)
     {
      int ry=y+i*GH_LRH;
      oLbl (PFX+k+"n"+(string)i, xLv,  ry+2, LvName(i), CTXT);
      oEdit(PFX+k+"g"+(string)i, xGap, ry, wGap-4,16, IntegerToString(s.lv[i].gap));
      oEdit(PFX+k+"l"+(string)i, xLot, ry, wLot-4,16, DoubleToString(s.lv[i].lot,2));
      oEdit(PFX+k+"p"+(string)i, xProf,ry, wProf-4,16,IntegerToString(s.lv[i].tp));
      oEdit(PFX+k+"k"+(string)i, xLock,ry, wLock-4,16,IntegerToString(s.lv[i].lock));
      oBtn (PFX+k+"o"+(string)i, xOn,  ry, wOn,16,  s.lv[i].on?"ON":"OFF", s.lv[i].on?CON:COFF);
     }
   y += LVLS*GH_LRH + 8;

   //--- live status rows
   oLbl(PFX+k+"sLvl",L,y,"Levels: 0",CTXT); y+=18;
   oLbl(PFX+k+"sPL", L,y,"P/L: 0.00",CTXT); y+=GH_RH;
   oBtn(PFX+k+"clsAll",L,y,GH_W-2*GH_PAD,20,"CLOSE "+side,COFF); y+=GH_RH+2;
   return y;
  }

//--- live position table (both sides). Use a MONOSPACE font so the fixed-
//--- width columns actually line up under the header.
void BuildPosTable(int x,int y,int w)
  {
   oRect(PFX"pt_bg",x,y,w,26+18*10,C'16,18,24',CGOLD);
   //--- header rendered in the same monospace layout as the rows
   string hdr = StringFormat("%-3s %-5s %-6s %-10s %-9s %-6s","#","Side","Lot","Entry","P/L","State");
   if(ObjectFind(0,PFX"pt_h")<0) ObjectCreate(0,PFX"pt_h",OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,PFX"pt_h",OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,PFX"pt_h",OBJPROP_XDISTANCE,x+10); ObjectSetInteger(0,PFX"pt_h",OBJPROP_YDISTANCE,y+6);
   ObjectSetString(0,PFX"pt_h",OBJPROP_TEXT,hdr);
   ObjectSetString(0,PFX"pt_h",OBJPROP_FONT,"Consolas"); ObjectSetInteger(0,PFX"pt_h",OBJPROP_FONTSIZE,GH_FS+1);
   ObjectSetInteger(0,PFX"pt_h",OBJPROP_COLOR,CGOLD); ObjectSetInteger(0,PFX"pt_h",OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,PFX"pt_h",OBJPROP_HIDDEN,true);
   for(int i=0;i<10;i++)
     {
      string nm=PFX"pt_"+(string)i;
      if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,x+10); ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y+26+i*18);
      ObjectSetString(0,nm,OBJPROP_TEXT," ");                 // blank, not the object name
      ObjectSetString(0,nm,OBJPROP_FONT,"Consolas"); ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,GH_FS+1);
      ObjectSetInteger(0,nm,OBJPROP_COLOR,CTXT); ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
     }
  }

//--- minimized layout: just a compact title bar with the [+] and RUN/basket
void BuildMinimized()
  {
   int w=300, h=26;
   oRect(PFX"mini_bg",GH_X,GH_Y,w,h,C'18,20,26',CGOLD);
   oBtn (PFX"minbtn", GH_X+6, GH_Y+4, 22,18, "+", CBTN);   // maximize
   oLbl (PFX"mini_t", GH_X+34,GH_Y+6, "GridHedge", CGOLD, GH_FS+1, true);
   oBtn (PFX"m_run",  GH_X+120,GH_Y+4, 80,18, g.running?"RUN":"STOP", g.running?CON:COFF);
   oLbl (PFX"m_bskt", GH_X+208,GH_Y+7, "P/L: 0.00", CGOLD, GH_FS, true);
  }

void PanelCreate()
  {
   if(g_min) { BuildMinimized(); return; }

   int bxB=GH_X, bxS=GH_X+GH_W+GH_GAP;
   int yb=BuildSide(bxB,"BUY","b",CHBUY,CBUYBG,g.buy);
   int ys=BuildSide(bxS,"SELL","s",CHSELL,CSELLBG,g.sell);
   //--- minimize button on the BUY header (top-right of the whole panel)
   int fw=GH_W*2+GH_GAP;
   oBtn(PFX"minbtn", GH_X+fw-24, GH_Y+4, 20,18, "-", CBTN);   // minimize

   int y=MathMax(yb,ys)+6;
   oRect(PFX"m_bg",GH_X,y,fw,28,C'18,20,26',CGOLD);
   oBtn(PFX"m_run",GH_X+8,  y+5,120,18,g.running?"RUNNING":"STOPPED",g.running?CON:COFF);
   oBtn(PFX"m_all",GH_X+138,y+5,120,18,"CLOSE ALL",COFF);
   oLbl(PFX"m_bskt",GH_X+270,y+8,"Basket P/L: 0.00",CGOLD,GH_FS+1,true);
   y+=34;
   BuildPosTable(GH_X,y,fw);
  }
void PanelDestroy(){ ObjectsDeleteAll(0,PFX); }

//--- refresh dynamic parts
void SidePanelUpdate(string k,const ENUM_POSITION_TYPE side,const SSide &s)
  {
   int n=SideCount(side); double pl=SideFloating(side);
   if(ObjectFind(0,PFX+k+"sLvl")>=0)ObjectSetString(0,PFX+k+"sLvl",OBJPROP_TEXT,StringFormat("Levels: %d/%d",n,InpMaxLevels));
   if(ObjectFind(0,PFX+k+"sPL")>=0){ObjectSetString(0,PFX+k+"sPL",OBJPROP_TEXT,StringFormat("P/L: %.2f",pl));
                                    ObjectSetInteger(0,PFX+k+"sPL",OBJPROP_COLOR,pl>=0?CON:CHSELL);}
   if(ObjectFind(0,PFX+k+"ST")>=0) ObjectSetInteger(0,PFX+k+"ST",OBJPROP_BGCOLOR,s.enabled?CON:CBTN);
   for(int i=0;i<LVLS;i++)
      if(ObjectFind(0,PFX+k+"o"+(string)i)>=0)
        { ObjectSetString(0,PFX+k+"o"+(string)i,OBJPROP_TEXT,s.lv[i].on?"ON":"OFF");
          ObjectSetInteger(0,PFX+k+"o"+(string)i,OBJPROP_BGCOLOR,s.lv[i].on?CON:COFF); }
  }

void PosTableUpdate()
  {
   //--- gather up to 10 positions, oldest first
   ulong tk[]; int n=0;
   for(int i=0;i<PositionsTotal();i++)
     { ulong t=PositionGetTicket(i); if(t==0)continue;
       if(PositionGetString(POSITION_SYMBOL)!=m_sym)continue;
       if(PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
       ArrayResize(tk,n+1);tk[n]=t;n++; if(n>=10)break; }
   for(int r=0;r<10;r++)
     {
      string nm=PFX"pt_"+(string)r; if(ObjectFind(0,nm)<0)continue;
      if(r<n && PositionSelectByTicket(tk[r]))
        {
         bool lng=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
         double op=PositionGetDouble(POSITION_PRICE_OPEN);
         double pl=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
         double vol=PositionGetDouble(POSITION_VOLUME);
         double slv=PositionGetDouble(POSITION_SL);
         string st = (slv>0)? "LOCK" : (pl>=0? "OPEN+" : "OPEN-");
         //--- monospace, fixed-width columns to match the header
         ObjectSetString(0,nm,OBJPROP_TEXT,StringFormat("%-3d %-5s %-6.2f %-10.*f %-9.2f %-6s",
              r+1, lng?"BUY":"SELL", vol, m_digits, op, pl, st));
         ObjectSetInteger(0,nm,OBJPROP_COLOR, pl>=0?CTXT:CHSELL);
        }
      else ObjectSetString(0,nm,OBJPROP_TEXT," ");
     }
  }

void PanelUpdate()
  {
   if(!InpShowPanel)return;
   double bk=BasketFloating();

   if(g_min)
     {
      //--- minimized bar: compact run + P/L only
      if(ObjectFind(0,PFX"m_run")>=0){ObjectSetString(0,PFX"m_run",OBJPROP_TEXT,m_halted?"HALT":(g.running?"RUN":"STOP"));
                                      ObjectSetInteger(0,PFX"m_run",OBJPROP_BGCOLOR,m_halted?COFF:(g.running?CON:COFF));}
      if(ObjectFind(0,PFX"m_bskt")>=0){ObjectSetString(0,PFX"m_bskt",OBJPROP_TEXT,StringFormat("P/L: %.2f",bk));
                                       ObjectSetInteger(0,PFX"m_bskt",OBJPROP_COLOR,bk>=0?CON:CHSELL);}
      ChartRedraw(0);
      return;
     }

   SidePanelUpdate("b",POSITION_TYPE_BUY, g.buy);
   SidePanelUpdate("s",POSITION_TYPE_SELL,g.sell);
   if(ObjectFind(0,PFX"m_bskt")>=0){ObjectSetString(0,PFX"m_bskt",OBJPROP_TEXT,StringFormat("Basket P/L: %.2f",bk));
                                    ObjectSetInteger(0,PFX"m_bskt",OBJPROP_COLOR,bk>=0?CON:CHSELL);}
   if(ObjectFind(0,PFX"m_run")>=0){ObjectSetString(0,PFX"m_run",OBJPROP_TEXT,m_halted?"HALTED":(g.running?"RUNNING":"STOPPED"));
                                   ObjectSetInteger(0,PFX"m_run",OBJPROP_BGCOLOR,m_halted?COFF:(g.running?CON:COFF));}
   PosTableUpdate();
   ChartRedraw(0);
  }

//--- numeric read helper
double ReadNum(string n,double def){ if(ObjectFind(0,n)<0)return def; double v=StringToDouble(ObjectGetString(0,n,OBJPROP_TEXT)); return v; }

//====================================================================
//  EVENTS
//====================================================================
void PullSideEdits(string k,SSide &s)
  {
   //--- base fields (shared): lot/prot/lock/bs read from whichever side edited
   double v;
   v=ReadNum(PFX+k+"eLot",g.lot); if(v>0)g.lot=v;
   v=ReadNum(PFX+k+"ePrt",g.prot);if(v>=0)g.prot=(int)v;
   v=ReadNum(PFX+k+"eLk", g.lock);if(v>=0)g.lock=(int)v;
   v=ReadNum(PFX+k+"eBS", g.bs);  if(v>=0)g.bs=(int)v;
   v=ReadNum(PFX+k+"eTgt",s.target); s.target=v;   // 0 = off
   //--- per-level rows
   for(int i=0;i<LVLS;i++)
     { double gg=ReadNum(PFX+k+"g"+(string)i,s.lv[i].gap); if(gg>0)s.lv[i].gap=(int)gg;
       double ll=ReadNum(PFX+k+"l"+(string)i,s.lv[i].lot); if(ll>0)s.lv[i].lot=ll;
       double pp=ReadNum(PFX+k+"p"+(string)i,s.lv[i].tp);  if(pp>0)s.lv[i].tp=(int)pp;
       double kk=ReadNum(PFX+k+"k"+(string)i,s.lv[i].lock);if(kk>=0)s.lv[i].lock=(int)kk; }
  }

void SideReport(const ENUM_POSITION_TYPE side)
  {
   int n=SideCount(side); double pl=SideFloating(side);
   bool f=false; double last=LastEntryPrice(side,f);
   Log(StringFormat("REPORT %s: levels=%d floatPL=%.2f lastEntry=%.*f",
        side==POSITION_TYPE_BUY?"BUY":"SELL",n,pl,m_digits, f?last:0.0));
  }

void OnChartEvent(const int id,const long &lp,const double &dp,const string &sp)
  {
   if(id==CHARTEVENT_OBJECT_ENDEDIT)
     { if(StringFind(sp,PFX)!=0)return;
       PullSideEdits("b",g.buy); PullSideEdits("s",g.sell);
       Log(StringFormat("edit: lot=%.2f prot=%d lock=%d bs=%d buyTgt=%.2f sellTgt=%.2f",
            g.lot,g.prot,g.lock,g.bs,g.buy.target,g.sell.target));
       ChartRedraw(0); return; }

   if(id!=CHARTEVENT_OBJECT_CLICK)return;
   if(StringFind(sp,PFX)!=0)return;

   //--- minimize / maximize toggle: rebuild the panel in the other mode
   if(sp==PFX"minbtn"){ g_min=!g_min; PanelDestroy(); PanelCreate(); PanelUpdate(); return; }
   //--- master
   if(sp==PFX"m_run"){ if(m_halted){m_halted=false;m_start_equity=AccountInfoDouble(ACCOUNT_EQUITY);Log("halt cleared");} g.running=!g.running; }
   else if(sp==PFX"m_all"){ CloseAll("panel CLOSE ALL"); }
   //--- BUY controls
   else if(sp==PFX"bST"){ g.buy.enabled=true;  Log("BUY ST: entries ON"); }
   else if(sp==PFX"bPU"){ g.buy.enabled=false; Log("BUY PU: entries paused"); }
   else if(sp==PFX"bCL"){ CloseSide(POSITION_TYPE_BUY,"CL"); }
   else if(sp==PFX"bSY"){ PanelUpdate(); Log("BUY SY: resynced"); }
   else if(sp==PFX"bREP"){ SideReport(POSITION_TYPE_BUY); }
   else if(sp==PFX"bclsAll"){ CloseSide(POSITION_TYPE_BUY,"panel close BUY"); }
   //--- SELL controls
   else if(sp==PFX"sST"){ g.sell.enabled=true;  Log("SELL ST: entries ON"); }
   else if(sp==PFX"sPU"){ g.sell.enabled=false; Log("SELL PU: entries paused"); }
   else if(sp==PFX"sCL"){ CloseSide(POSITION_TYPE_SELL,"CL"); }
   else if(sp==PFX"sSY"){ PanelUpdate(); Log("SELL SY: resynced"); }
   else if(sp==PFX"sREP"){ SideReport(POSITION_TYPE_SELL); }
   else if(sp==PFX"sclsAll"){ CloseSide(POSITION_TYPE_SELL,"panel close SELL"); }
   else
     {
      //--- per-level ON/OFF toggles: keys like "b o<i>" / "s o<i>"
      for(int i=0;i<LVLS;i++)
        { if(sp==PFX"b"+"o"+(string)i){ g.buy.lv[i].on=!g.buy.lv[i].on;  Log(StringFormat("BUY %s %s",LvName(i),g.buy.lv[i].on?"ON":"OFF")); }
          if(sp==PFX"s"+"o"+(string)i){ g.sell.lv[i].on=!g.sell.lv[i].on;Log(StringFormat("SELL %s %s",LvName(i),g.sell.lv[i].on?"ON":"OFF")); } }
     }
   ObjectSetInteger(0,sp,OBJPROP_STATE,false);
   PanelUpdate();
  }
//+------------------------------------------------------------------+
