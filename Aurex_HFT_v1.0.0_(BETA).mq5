#property strict
#property version   "1.00"
#property description "Aurex breakout-straddle demo beta."
#property description "One chart instance per symbol. Test before live use."

#include "Aurex_Core.mqh"

input group "Identity & Execution"
input ulong MagicNumberGold=26090101; // Gold instance magic
input ulong MagicNumberBtc=26090102;  // BTC instance magic
input AX_EXECUTION_MODE ExecutionMode=SERVER_PENDING; // Entry execution
input int Slippage=20;               // Market-request deviation, points
input double CommissionPerLotRoundTurn=7.0; // Account USD per lot round trip
input bool CancelPendingsOnDeinit=true; // Cancel managed pendings on removal

input group "Symbols & Schedule"
input string GoldSymbol="";          // Exact gold symbol; blank auto-detects
input string BtcSymbol="";           // Exact BTC symbol; blank auto-detects
input int TradeGoldDays=62;          // Mon-Fri; Sunday is bit zero
input int TradeBtcDays=65;            // Saturday and Sunday
input int StartHour=0;               // Entry-session start, server hour
input int EndHour=24;                // Entry-session end, server hour
input int ExcludeStartHour=0;        // Equal exclude hours disable exclusion
input int ExcludeEndHour=0;          // Exclude-window end, server hour
input int FridayCloseHour=21;        // Gold flatten hour on Friday
input int SundayCloseHour=21;        // BTC flatten hour on Sunday

input group "Position Sizing"
input AX_LOT_MODE LotSizingMode=PCT_EQUITY; // Risk capital basis
input double FixedLot=0.01;          // Fixed-mode lot size
input double RiskPercent=1.0;        // Percentage risk budget per entry
input double MarginBufferPercent=30.0; // Free margin retained
input double MaxLot=0.10;            // Absolute lot cap

input group "Risk Control"
input double DailyLossLimitPercent=3.0; // Equity loss from daily snapshot
input bool CloseOnCircuitBreaker=true; // Flatten after daily loss trip
input double DailyProfitTargetPercent=0.0; // Zero disables profit lock
input int MaxTradesPerDay=20;        // Maximum entry-position count
input int MaxConsecutiveLosses=3;    // Stop after this many losing exits
input double MaxCostToRiskRatio=0.35; // Estimated cost / risk budget
input int MaxDoubleFillsPerDay=0;     // Widen after exceeding this count

input group "Order Geometry"
input double DeltaPoints=100.0;      // Trigger distance, symbol points
input double MaxDistancePoints=50.0; // Re-centering hysteresis
input int RecentreMinMs=500;         // Minimum interval per pending side
input double StopPoints=300.0;       // Nominal protective stop
input double TpMultiplier=1.5;       // TP / stop; zero enables trailing-only
input double MinNetTargetPoints=50.0; // Minimum estimated after-cost target
input int MaxSpreadPoints=60;        // Maximum live spread
input int SpreadStableMs=1000;       // Required continuous spread stability
input int MaxQuoteAgeMs=1500;        // Maximum age for trading decisions

input group "Volatility Gate"
input int AtrPeriod=14;              // M1 ATR period
input double MinAtrPoints=50.0;      // Minimum closed-bar ATR
input double MaxAtrPoints=3000.0;    // Maximum closed-bar ATR
input int CooldownAfterWinSecs=15;   // Cooldown after non-losing exit
input int CooldownAfterLossSecs=60;  // Cooldown after losing exit
input int VirtualTriggerConfirmTicks=1; // Consecutive crossing observations

input group "Trailing"
input double TslTriggerPoints=200.0; // Profit required to activate trailing
input double TslPoints=150.0;        // Trailing distance
input double TslStepPoints=25.0;     // Minimum improvement
input int TslMinIntervalMs=500;      // Minimum trailing-request interval
input double BreakEvenAtPoints=0.0; // Zero disables break-even adjustment

input group "Traffic & Telemetry"
input double MaxRequestsPerSecond=4.0; // Per-instance sustained request rate
input double BurstRequests=8.0;     // Per-instance token capacity
input int ReconcileIntervalSecs=2;  // Broker-state reconciliation interval
input bool ShowDashboard=true;      // Show chart status and kill button
input int LogLevel=1;               // 0 errors, 1 state, 2 requests, 3 verbose
input bool WriteCsvJournal=true;    // Write confirmed deals to CSV

input group "Beta Diagnostics"
input double InitialSlippageEstimatePoints=10.0; // Cold-start adverse estimate
input int QuoteStallCloseMs=5000;    // Stall logging threshold; never blind-close
input bool RunSelfTests=true;       // Run elementary arithmetic checks

#include "Aurex_Engine.mqh"

AxEngine Aurex;

int OnInit()
{
   int result=Aurex.Start();
   if(result!=INIT_SUCCEEDED)
   {
      Aurex.Stop();
      return result;
   }

   ResetLastError();
   if(!EventSetMillisecondTimer(50))
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
   Aurex.QuoteEvent();
}

void OnTimer()
{
   Aurex.TimerEvent();
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

// ==================== END OF FILE: Aurex_HFT.mq5 ====================
