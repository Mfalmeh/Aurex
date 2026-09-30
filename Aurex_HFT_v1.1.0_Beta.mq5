#property strict
#property version   "1.10"
#property description "Aurex server-pending breakout straddle beta."
#property description "Demo first. Broker execution must be evaluated."

enum AX_LOT_MODE
{
   FIXED=0,
   PCT_BALANCE=1,
   PCT_EQUITY=2,
   PCT_FREE_MARGIN=3
};

input group "Identity"
input ulong MagicNumberGold=26090101;
input ulong MagicNumberBtc=26090102;
input string GoldSymbol="";
input string BtcSymbol="";
input bool CancelPendingsOnDeinit=true;

input group "Schedule - broker server time"
input int TradeGoldDays=62;
input int TradeBtcDays=65;
input int StartHour=0;
input int EndHour=24;
input int ExcludeStartHour=0;
input int ExcludeEndHour=0;
input int FridayCloseHour=21;
input int SundayCloseHour=21;

input group "Sizing"
input AX_LOT_MODE LotSizingMode=PCT_EQUITY;
input double FixedLot=0.01;
input double RiskPercent=1.0;
input double MaxLot=0.10;
input double MarginBufferPercent=30.0;
input double CommissionPerLotRoundTurn=7.0;
input double InitialSlippageEstimatePoints=10.0;
input int Slippage=20;

input group "Account and instance limits"
input double DailyLossLimitPercent=3.0;
input bool CloseOnCircuitBreaker=true;
input double DailyProfitTargetPercent=0.0;
input int MaxTradesPerDay=20;
input int MaxConsecutiveLosses=3;
input double MaxCostToRiskRatio=0.35;
input int CooldownAfterWinSecs=15;
input int CooldownAfterLossSecs=60;

input group "Geometry - symbol points, not pips"
input double DeltaPoints=50.0;
input double AtrDeltaFactor=0.08;
input double StopPoints=300.0;
input double AtrStopFactor=0.50;
input double TpMultiplier=1.5;
input double MinNetTargetPoints=50.0;
input double MaxDistancePoints=50.0;
input int RecentreMinMs=500;
input int MaxSpreadPoints=100;
input int SpreadStableMs=500;
input int MaxQuoteAgeMs=2000;

input group "Volatility"
input int AtrPeriod=14;
input double MinAtrPoints=0.0;
input double MaxAtrPoints=0.0; // Zero disables upper ATR bound

input group "Protection"
input double TslTriggerPoints=200.0;
input double TslPoints=150.0;
input double TslStepPoints=25.0;
input int TslMinIntervalMs=500;
input double BreakEvenAtPoints=0.0;

input group "Traffic and diagnostics"
input double MaxRequestsPerSecond=4.0;
input double BurstRequests=8.0;
input int PairSettleMs=1000;
input bool ShowDashboard=true;
input bool WriteCsvJournal=true;
input int LogLevel=1;

#include "Aurex_Engine.mqh"

AxEngine Aurex;

int OnInit()
{
   int rc=Aurex.Start();
   if(rc!=INIT_SUCCEEDED)
   {
      Aurex.Stop();
      return rc;
   }

   ResetLastError();
   if(!EventSetMillisecondTimer(100))
   {
      Print("AUREX event=TIMER_FAILED error=",GetLastError());
      Aurex.Stop();
      return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Aurex.Stop();
}

void OnTick()
{
   Aurex.Step(false);
}

void OnTimer()
{
   Aurex.Step(true);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   Aurex.TradeEvent(trans,request,result);
}

void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   Aurex.ChartEvent(id,sparam);
}
