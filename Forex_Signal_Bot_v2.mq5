//+------------------------------------------------------------------+
//| Forex_Signal_Bot_v2.mq5                                          |
//| Signal-only MT5 EA. No order placement, modification or closing. |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property description "Signal-only Forex EA with virtual trade tracking; never places orders."

input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_M15;
input double RiskPercent = 0.5;
input double RewardRiskRatio = 1.5;
input int FastEMA = 50;
input int SlowEMA = 200;
input int RSIPeriod = 14;
input int MACDFast = 12;
input int MACDSlow = 26;
input int MACDSignal = 9;
input int ATRPeriod = 14;
input double ATRStopMultiplier = 1.5;
input int MaxSpreadPoints = 25;
input int MaxSignalsPerDay = 5;
input bool EnablePopupAlerts = true;
input bool EnablePushNotifications = false;
input bool EnableVirtualTesting = true;
input bool ExportCSV = true;
input string CSVFileName = "Forex_Signal_Bot_v2_log.csv";

int hFastEMA = INVALID_HANDLE, hSlowEMA = INVALID_HANDLE;
int hRSI = INVALID_HANDLE, hMACD = INVALID_HANDLE, hATR = INVALID_HANDLE;
datetime lastBarTime = 0;
int signalsToday = 0, currentDayKey = -1;
int virtualClosed = 0, virtualWins = 0, virtualLosses = 0;
double netR = 0.0, grossWinR = 0.0, grossLossR = 0.0;
double peakR = 0.0, maxDrawdownR = 0.0;

struct VirtualTrade
{
   bool active;
   int direction;
   double entry, sl, tp, lots;
};
VirtualTrade vt;

double NormalizePrice(const double p)
{
   return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

double NormalizeLotsDown(const double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0 || minLot <= 0.0) return 0.0;
   double result = MathFloor((MathMin(lots, maxLot) + 1e-10) / step) * step;
   if(result < minLot) return 0.0;
   return NormalizeDouble(result, 8);
}

double SuggestedLots(const ENUM_ORDER_TYPE side, const double entry, const double sl)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double lossOneLot = 0.0;
   if(riskMoney <= 0.0 || !OrderCalcProfit(side, _Symbol, 1.0, entry, sl, lossOneLot))
      return 0.0;
   lossOneLot = MathAbs(lossOneLot);
   if(lossOneLot <= 0.0) return 0.0;
   return NormalizeLotsDown(riskMoney / lossOneLot);
}

bool ReadValue(const int handle, const int buffer, const int shift, double &value)
{
   double data[1];
   if(handle == INVALID_HANDLE || CopyBuffer(handle, buffer, shift, 1, data) != 1)
      return false;
   value = data[0];
   return MathIsValidNumber(value);
}

int MakeDayKey(datetime when)
{
   MqlDateTime dt;
   TimeToStruct(when, dt);
   return dt.year * 1000 + dt.day_of_year;
}

void LogCSV(const string eventName, const string direction, double entry,
            double sl, double tp, double lots, double resultR, const string note)
{
   if(!ExportCSV) return;
   int f = FileOpen(CSVFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(f == INVALID_HANDLE) { Print("CSV open failed: ", GetLastError()); return; }
   if(FileSize(f) == 0)
      FileWrite(f,"event","symbol","timeframe","time","direction","entry","sl","tp",
                "lots","risk_percent","spread_points","result_R","net_R","note");
   FileSeek(f, 0, SEEK_END);
   FileWrite(f,eventName,_Symbol,EnumToString(SignalTimeframe),
      TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),direction,
      DoubleToString(entry,_Digits),DoubleToString(sl,_Digits),DoubleToString(tp,_Digits),
      DoubleToString(lots,2),DoubleToString(RiskPercent,2),
      (string)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD),DoubleToString(resultR,3),
      DoubleToString(netR,3),note);
   FileClose(f);
}

string StatsText()
{
   double wr = virtualClosed > 0 ? 100.0 * virtualWins / virtualClosed : 0.0;
   string pf = grossLossR > 0.0 ? DoubleToString(grossWinR/grossLossR,2)
               : (grossWinR > 0.0 ? "No losses yet" : "N/A");
   return StringFormat("Virtual closes: %d | Wins: %d | Losses: %d | Win rate: %.1f%%\nNet R: %.2f | PF (R): %s | Max DD: %.2f R",
                       virtualClosed,virtualWins,virtualLosses,wr,netR,pf,maxDrawdownR);
}

void FinishVirtual(const double resultR, const string why, const double exitPrice)
{
   if(!vt.active) return;
   string dir = vt.direction > 0 ? "BUY" : "SELL";
   virtualClosed++;
   if(resultR > 0.0) { virtualWins++; grossWinR += resultR; }
   else { virtualLosses++; grossLossR += MathAbs(resultR); }
   netR += resultR;
   peakR = MathMax(peakR, netR);
   maxDrawdownR = MathMax(maxDrawdownR, peakR-netR);
   LogCSV("VIRTUAL_CLOSE",dir,vt.entry,vt.sl,vt.tp,vt.lots,resultR,
          why+" at "+DoubleToString(exitPrice,_Digits));
   Print("Virtual ",dir," closed: ",why," R=",DoubleToString(resultR,2)," | ",StatsText());
   vt.active = false;
}

void CheckVirtualTrade(const MqlTick &tick)
{
   if(!EnableVirtualTesting || !vt.active) return;
   if(vt.direction > 0)
   {
      if(tick.bid <= vt.sl) FinishVirtual(-1.0,"SL",tick.bid);
      else if(tick.bid >= vt.tp) FinishVirtual(RewardRiskRatio,"TP",tick.bid);
   }
   else
   {
      if(tick.ask >= vt.sl) FinishVirtual(-1.0,"SL",tick.ask);
      else if(tick.ask <= vt.tp) FinishVirtual(RewardRiskRatio,"TP",tick.ask);
   }
}

void PublishSignal(const int dir, double entry, double sl, double tp,
                   double lots, const string reason)
{
   string side = dir > 0 ? "BUY" : "SELL";
   string lotText = lots > 0.0 ? DoubleToString(lots,2) : "Unavailable (min lot may exceed risk)";
   string msg = StringFormat("%s %s | %s | Entry %s | SL %s | TP %s | Suggested lots %s | Risk %.2f%% | %s",
      _Symbol,side,EnumToString(SignalTimeframe),DoubleToString(entry,_Digits),
      DoubleToString(sl,_Digits),DoubleToString(tp,_Digits),lotText,RiskPercent,reason);
   Print(msg);
   Comment("FOREX SIGNAL BOT v2 — SIGNAL ONLY\n",msg,
           "\nNo real orders are ever placed.\n",StatsText());
   if(EnablePopupAlerts) Alert(msg);
   if(EnablePushNotifications) SendNotification(msg);
   LogCSV("SIGNAL",side,entry,sl,tp,lots,0.0,reason);
}

int OnInit()
{
   if(RiskPercent <= 0.0 || RiskPercent > 5.0 || RewardRiskRatio <= 0.0 ||
      ATRStopMultiplier <= 0.0 || FastEMA <= 0 || SlowEMA <= FastEMA ||
      MaxSpreadPoints < 0 || MaxSignalsPerDay < 1)
      return INIT_PARAMETERS_INCORRECT;

   hFastEMA = iMA(_Symbol,SignalTimeframe,FastEMA,0,MODE_EMA,PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol,SignalTimeframe,SlowEMA,0,MODE_EMA,PRICE_CLOSE);
   hRSI = iRSI(_Symbol,SignalTimeframe,RSIPeriod,PRICE_CLOSE);
   hMACD = iMACD(_Symbol,SignalTimeframe,MACDFast,MACDSlow,MACDSignal,PRICE_CLOSE);
   hATR = iATR(_Symbol,SignalTimeframe,ATRPeriod);

   if(hFastEMA == INVALID_HANDLE || hSlowEMA == INVALID_HANDLE ||
      hRSI == INVALID_HANDLE || hMACD == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Print("Indicator initialization failed: ",GetLastError());
      return INIT_FAILED;
   }
   vt.active = false;
   currentDayKey = MakeDayKey(TimeCurrent());
   Print("Forex Signal Bot v2 ready. Signal-only mode; no orders are placed.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hFastEMA != INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA != INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hRSI != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hMACD != INVALID_HANDLE) IndicatorRelease(hMACD);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   Comment("");
   Print("Session virtual stats: ",StatsText());
}

void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;
   CheckVirtualTrade(tick);

   datetime bar = iTime(_Symbol,SignalTimeframe,0);
   if(bar <= 0 || bar == lastBarTime) return;
   lastBarTime = bar;

   int dayKey = MakeDayKey(TimeCurrent());
   if(dayKey != currentDayKey) { currentDayKey = dayKey; signalsToday = 0; }

   if(Bars(_Symbol,SignalTimeframe) < SlowEMA+10)
   {
      Comment("FOREX SIGNAL BOT v2\nWaiting for more history.\n",StatsText());
      return;
   }

   long spread = SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints)
   {
      Comment("FOREX SIGNAL BOT v2\nWAIT: spread ",(string)spread,
              " points exceeds limit ",(string)MaxSpreadPoints,"\n",StatsText());
      return;
   }

   double fast,slow,rsi,macdMain,macdSig,atr;
   if(!ReadValue(hFastEMA,0,1,fast) || !ReadValue(hSlowEMA,0,1,slow) ||
      !ReadValue(hRSI,0,1,rsi) || !ReadValue(hMACD,0,1,macdMain) ||
      !ReadValue(hMACD,1,1,macdSig) || !ReadValue(hATR,0,1,atr))
      return;

   double close1 = iClose(_Symbol,SignalTimeframe,1);
   if(close1 <= 0.0 || atr <= 0.0) return;

   bool buy = fast > slow && close1 > fast && rsi > 50.0 && rsi < 70.0 && macdMain > macdSig;
   bool sell = fast < slow && close1 < fast && rsi < 50.0 && rsi > 30.0 && macdMain < macdSig;

   if(!buy && !sell)
   {
      Comment("FOREX SIGNAL BOT v2 — SIGNAL ONLY\n",_Symbol," | ",EnumToString(SignalTimeframe),
              "\nSignal: WAIT / no full confirmation",
              "\nEMA: ",DoubleToString(fast,_Digits)," / ",DoubleToString(slow,_Digits),
              " | RSI: ",DoubleToString(rsi,2),
              " | MACD: ",DoubleToString(macdMain,6)," / ",DoubleToString(macdSig,6),
              "\nSignals today: ",(string)signalsToday," / ",(string)MaxSignalsPerDay,
              "\n",StatsText(),"\nNo orders are placed.");
      return;
   }

   if(signalsToday >= MaxSignalsPerDay)
   {
      Comment("FOREX SIGNAL BOT v2\nWAIT: daily signal limit reached.\n",StatsText());
      return;
   }
   if(EnableVirtualTesting && vt.active)
   {
      Comment("FOREX SIGNAL BOT v2\nSignal skipped: virtual trade already open.\n",StatsText());
      return;
   }

   int dir = buy ? 1 : -1;
   ENUM_ORDER_TYPE orderSide = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double entry = buy ? tick.ask : tick.bid;
   double dist = atr * ATRStopMultiplier;
   double sl = buy ? entry-dist : entry+dist;
   double tp = buy ? entry+dist*RewardRiskRatio : entry-dist*RewardRiskRatio;
   entry = NormalizePrice(entry); sl = NormalizePrice(sl); tp = NormalizePrice(tp);

   long stops = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = (double)stops * _Point;
   if(minDist > 0.0 && (MathAbs(entry-sl) < minDist || MathAbs(tp-entry) < minDist))
   {
      Comment("FOREX SIGNAL BOT v2\nWAIT: suggested SL/TP violates broker minimum distance.");
      return;
   }

   double riskLots = SuggestedLots(orderSide,entry,sl);
   string reason = StringFormat("EMA trend + RSI %.2f + MACD confirmation",rsi);
   PublishSignal(dir,entry,sl,tp,riskLots,reason);
   signalsToday++;

   if(EnableVirtualTesting && !vt.active)
   {
      vt.active = true;
      vt.direction = dir;
      vt.entry = entry; vt.sl = sl; vt.tp = tp; vt.lots = riskLots;
      LogCSV("VIRTUAL_OPEN",buy ? "BUY" : "SELL",entry,sl,tp,riskLots,0.0,reason);
   }
}
