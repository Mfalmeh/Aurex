// Part 1: types, ownership, profile, quotes, schedule and daily circuits.
// This file opens AxEngine. Part 4 closes it.

struct AxBook
{
   int orders;
   int positions;
   ulong buy;
   ulong sell;
   ulong position;
   bool foreign;
};

struct AxPlan
{
   double buy;
   double sell;
   double buy_sl;
   double sell_sl;
   double buy_tp;
   double sell_tp;
   double lots;
   double unit_loss;
   double unit_cost;
   double risk_budget;
   double stop_points;
   double delta_points;
};

int AxDate(const datetime when)
{
   MqlDateTime t;
   if(!TimeToStruct(when,t))
      return 0;
   return t.year*10000+t.mon*100+t.day;
}

datetime AxMidnight(const datetime when)
{
   MqlDateTime t;
   if(!TimeToStruct(when,t))
      return 0;
   t.hour=0;
   t.min=0;
   t.sec=0;
   return StructToTime(t);
}

bool AxHours(const int hour,const int start,const int finish)
{
   if(start==finish)
      return true;
   if(start<finish)
      return hour>=start && hour<finish;
   return hour>=start || hour<finish;
}

double AxFloorLots(const double value,const double step)
{
   if(step<=0.0 || value<=0.0)
      return 0.0;
   return NormalizeDouble(MathFloor(value/step+1e-9)*step,8);
}

ulong AxHash(const string text)
{
   ulong h=1469598103934665603;
   for(int i=0;i<StringLen(text);i++)
   {
      h^=(ulong)StringGetCharacter(text,i);
      h*=1099511628211;
   }
   return h;
}

class AxEngine
{
private:
   string symbol;
   string ap;
   string ip;
   string objects;
   string state;
   string state_reason;

   ulong magic;
   bool gold;
   bool btc;
   bool hedge;
   bool initialized;
   bool owns;
   bool hard_halt;
   bool uncertain;
   bool cancel_requested;
   bool flatten_requested;
   bool loss_trip;
   bool profit_trip;
   bool streak_trip;
   bool history_dirty;
   bool session_warning;
   bool quote_valid;
   bool atr_valid;

   double owner_value;
   double point;
   double tick_size;
   double volume_min;
   double volume_max;
   double volume_step;
   int digits;
   int stops;
   int freeze;
   long fill_flags;
   long execution;
   long trade_mode;
   long order_flags;
   long expiration_flags;

   int atr_handle;
   double atr_points;
   MqlTick quote;
   long last_quote_msc;
   ulong last_quote_local;
   ulong stable_since;
   bool spread_stable;
   double spread;

   int day_key;
   double day_equity;
   int trades_today;
   int losses;
   datetime cooldown_until;
   datetime last_exit_time;

   double tokens;
   ulong refill_at;
   ulong blocked_until;
   ulong reduced_until;
   int backoff_ms;
   ulong settle_until;
   ulong last_profile;
   ulong last_atr;
   ulong last_history;
   ulong last_heartbeat;
   ulong last_panel;
   ulong last_save;
   ulong last_trail;
   ulong last_modify;
   bool modify_buy_next;

   ulong cycle_buy;
   ulong cycle_sell;
   ulong first_fill;
   ulong seen_positions[];
   ulong journal_queue[];
   AxPlan plan;

   datetime Now()
   {
      datetime t=TimeCurrent();
      return t>0 ? t : TimeTradeServer();
   }

   string Key(const string suffix)
   {
      return ip+suffix;
   }

   double Load(const string name,const double fallback=0.0)
   {
      if(!GlobalVariableCheck(name))
         return fallback;
      return GlobalVariableGet(name);
   }

   void Log(const int level,const string event,const string detail)
   {
      if(level<=LogLevel)
         Print("AUREX event=",event,
               " symbol=",symbol," magic=",magic," ",detail);
   }

   void State(const string next,const string why)
   {
      if(state!=next || state_reason!=why)
         Log(1,"STATE","state="+next+" reason="+why);
      state=next;
      state_reason=why;
   }

   bool Invalid(const string text)
   {
      Print("AUREX event=INVALID_INPUT detail=",text);
      return false;
   }

   bool Validate()
   {
      double values[]={
         FixedLot,RiskPercent,MaxLot,MarginBufferPercent,
         CommissionPerLotRoundTurn,InitialSlippageEstimatePoints,
         DailyLossLimitPercent,DailyProfitTargetPercent,
         MaxCostToRiskRatio,DeltaPoints,AtrDeltaFactor,
         StopPoints,AtrStopFactor,TpMultiplier,MinNetTargetPoints,
         MaxDistancePoints,MinAtrPoints,MaxAtrPoints,
         TslTriggerPoints,TslPoints,TslStepPoints,
         BreakEvenAtPoints,MaxRequestsPerSecond,BurstRequests
      };
      for(int i=0;i<ArraySize(values);i++)
         if(!MathIsValidNumber(values[i]))
            return Invalid("Numeric input is not finite");

      if(MagicNumberGold==0 || MagicNumberBtc==0 ||
         MagicNumberGold==MagicNumberBtc)
         return Invalid("Magic numbers must be nonzero and different");
      if(GoldSymbol!="" && GoldSymbol==BtcSymbol)
         return Invalid("Gold and BTC symbols must differ");
      if((int)LotSizingMode<0 || (int)LotSizingMode>3)
         return Invalid("LotSizingMode");

      if(FixedLot<=0 || MaxLot<=0 || RiskPercent<=0 ||
         RiskPercent>10 || MarginBufferPercent<0 ||
         MarginBufferPercent>=100)
         return Invalid("Sizing limits");
      if(CommissionPerLotRoundTurn<0 ||
         InitialSlippageEstimatePoints<0 || Slippage<0)
         return Invalid("Commission/slippage");

      if(DailyLossLimitPercent<=0 || DailyLossLimitPercent>100 ||
         DailyProfitTargetPercent<0 || MaxTradesPerDay<1 ||
         MaxConsecutiveLosses<1 || MaxCostToRiskRatio<=0 ||
         MaxCostToRiskRatio>1)
         return Invalid("Risk limits");

      if(DeltaPoints<=0 || StopPoints<=0 || AtrDeltaFactor<0 ||
         AtrStopFactor<0 || TpMultiplier<0 ||
         MinNetTargetPoints<0 || MaxDistancePoints<=0 ||
         MaxSpreadPoints<1 || SpreadStableMs<0 ||
         MaxQuoteAgeMs<100 || RecentreMinMs<100)
         return Invalid("Geometry/quote limits");

      if(AtrPeriod<2 || MinAtrPoints<0 || MaxAtrPoints<0 ||
         (MaxAtrPoints>0 && MaxAtrPoints<=MinAtrPoints))
         return Invalid("ATR limits");

      if(TslTriggerPoints<0 || TslPoints<=0 ||
         TslStepPoints<=0 || TslMinIntervalMs<100 ||
         BreakEvenAtPoints<0)
         return Invalid("Trailing limits");

      if(MaxRequestsPerSecond<=0 || MaxRequestsPerSecond>50 ||
         BurstRequests<4 || BurstRequests>100 ||
         PairSettleMs<250 || PairSettleMs>10000 ||
         CooldownAfterWinSecs<0 || CooldownAfterLossSecs<0 ||
         LogLevel<0 || LogLevel>3)
         return Invalid("Traffic/cooldown limits");

      if(TradeGoldDays<0 || TradeGoldDays>127 ||
         TradeBtcDays<0 || TradeBtcDays>127 ||
         StartHour<0 || StartHour>23 ||
         EndHour<0 || EndHour>24 ||
         ExcludeStartHour<0 || ExcludeStartHour>23 ||
         ExcludeEndHour<0 || ExcludeEndHour>24 ||
         FridayCloseHour<0 || FridayCloseHour>24 ||
         SundayCloseHour<0 || SundayCloseHour>24)
         return Invalid("Schedule");
      return true;
   }

   bool Resolve()
   {
      string upper=symbol;
      StringToUpper(upper);
      gold=GoldSymbol!="" ? symbol==GoldSymbol :
           (StringFind(upper,"XAUUSD")>=0 ||
            StringFind(upper,"GOLD")>=0);
      btc=BtcSymbol!="" ? symbol==BtcSymbol :
          StringFind(upper,"BTCUSD")>=0;

      if(gold==btc)
         return false;

      magic=btc ? MagicNumberBtc : MagicNumberGold;
      return true;
   }

   bool Acquire()
   {
      // GlobalVariableTemp does not overwrite an existing variable.
      // Ownership is terminal-local, not shared between separate terminals.
      string key=Key("OWNER2");
      if(!GlobalVariableTemp(key))
         return false;

      double old=GlobalVariableGet(key);
      long now=(long)TimeLocal();
      long prior=(long)MathFloor(old/1000000.0);

      // A long lease avoids routine synchronous broker calls expiring it.
      if(old!=0.0 && prior>now-120 && prior<=now+120)
         return false;

      ulong chart=(ulong)ChartID();
      double tag=(double)(chart%999983+1);
      owner_value=(double)now*1000000.0+tag;
      owns=GlobalVariableSetOnCondition(key,owner_value,old);
      return owns;
   }

   bool OwnerValid()
   {
      if(!owns)
         return false;
      if(Load(Key("OWNER2"),-1.0)!=owner_value)
      {
         owns=false;
         hard_halt=true;
         State("HALTED","owner lease lost; this instance will not trade");
         return false;
      }
      return true;
   }

   void Heartbeat()
   {
      ulong now=GetTickCount64();
      if(now-last_heartbeat<1000 || !owns)
         return;
      last_heartbeat=now;

      double tag=owner_value-
         MathFloor(owner_value/1000000.0)*1000000.0;
      double next=(double)TimeLocal()*1000000.0+tag;

      if(!GlobalVariableSetOnCondition(Key("OWNER2"),next,owner_value))
      {
         owns=false;
         hard_halt=true;
         State("HALTED","owner lease lost");
         return;
      }
      owner_value=next;
   }

   bool Profile()
   {
      if(!SymbolSelect(symbol,true))
         return false;

      digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      point=SymbolInfoDouble(symbol,SYMBOL_POINT);
      tick_size=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
      volume_min=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
      volume_max=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
      volume_step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
      fill_flags=SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
      execution=SymbolInfoInteger(symbol,SYMBOL_TRADE_EXEMODE);
      order_flags=SymbolInfoInteger(symbol,SYMBOL_ORDER_MODE);
      expiration_flags=SymbolInfoInteger(symbol,SYMBOL_EXPIRATION_MODE);
      Distances();

      return point>0 && tick_size>0 && volume_min>0 &&
             volume_max>=volume_min && volume_step>0;
   }

   void Distances()
   {
      stops=(int)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
      freeze=(int)SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL);
      trade_mode=SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE);
   }

   double Up(const double price)
   {
      return NormalizeDouble(
         MathCeil(price/tick_size-1e-9)*tick_size,digits);
   }

   double Down(const double price)
   {
      return NormalizeDouble(
         MathFloor(price/tick_size+1e-9)*tick_size,digits);
   }

   bool ReadQuote()
   {
      MqlTick fresh;
      quote_valid=false;
      if(!SymbolInfoTick(symbol,fresh) ||
         fresh.bid<=0 || fresh.ask<fresh.bid || fresh.time_msc<=0)
         return false;

      ulong now=GetTickCount64();
      bool changed=(fresh.time_msc!=last_quote_msc ||
                    fresh.bid!=quote.bid || fresh.ask!=quote.ask);
      quote=fresh;
      spread=(quote.ask-quote.bid)/point;

      if(changed)
      {
         last_quote_msc=fresh.time_msc;
         last_quote_local=now;
      }

      if(spread>MaxSpreadPoints)
      {
         spread_stable=false;
         stable_since=0;
      }
      else if(!spread_stable)
      {
         spread_stable=true;
         stable_since=now;
      }

      quote_valid=true;
      return true;
   }

   long QuoteAge()
   {
      if(!quote_valid || last_quote_msc==0)
         return 2147483647;

      long local=(long)(GetTickCount64()-last_quote_local);
      long server=(long)Now()*1000-quote.time_msc;
      if(server<0)
         server=0;
      return local>server ? local : server;
   }

   void ReadAtr()
   {
      double values[1];
      atr_valid=false;
      if(atr_handle==INVALID_HANDLE)
         return;
      if(CopyBuffer(atr_handle,0,1,1,values)!=1 ||
         !MathIsValidNumber(values[0]) || values[0]<=0)
         return;
      atr_points=values[0]/point;
      atr_valid=true;
   }

   bool BrokerSession()
   {
      MqlDateTime t;
      if(!TimeToStruct(Now(),t))
         return false;

      int seconds=t.hour*3600+t.min*60+t.sec;
      bool today_found=false;

      // Also check spillover from a session starting the previous day.
      for(int pass=0;pass<2;pass++)
      {
         int weekday=(t.day_of_week+7-pass)%7;
         for(uint i=0;i<32;i++)
         {
            datetime from=0,to=0;
            if(!SymbolInfoSessionTrade(symbol,
                 (ENUM_DAY_OF_WEEK)weekday,i,from,to))
               break;

            if(pass==0)
               today_found=true;

            long raw_a=(long)from;
            long raw_b=(long)to;
            int a=(int)(raw_a%86400);
            int b=(int)(raw_b%86400);

            if(pass==0)
            {
               if(a==b)
                  return true;
               if(a<b && seconds>=a && seconds<b)
                  return true;
               if(a>b && seconds>=a)
                  return true;
            }
            else if(a>b && seconds<b)
               return true;
         }
      }

      if(today_found)
         return false;

      // Distinguish a closed weekday from a wholly absent weekly table.
      bool any=false;
      for(int d=0;d<7;d++)
      {
         datetime from=0,to=0;
         if(SymbolInfoSessionTrade(symbol,(ENUM_DAY_OF_WEEK)d,0,from,to))
         {
            any=true;
            break;
         }
      }

      if(any)
         return false;

      if(!session_warning)
      {
         Log(0,"SESSION_TABLE_ABSENT",
             "weekly table absent; configured schedule remains active");
         session_warning=true;
      }
      return true;
   }

   bool Schedule(string &why,bool &flatten)
   {
      flatten=false;
      MqlDateTime t;
      if(!TimeToStruct(Now(),t))
      {
         why="server time unavailable";
         return false;
      }

      if((gold && t.day_of_week==5 && t.hour>=FridayCloseHour) ||
         (btc && t.day_of_week==0 && t.hour>=SundayCloseHour))
      {
         flatten=true;
         why="weekly flatten";
         return false;
      }

      int mask=btc ? TradeBtcDays : TradeGoldDays;
      if((mask & (1<<t.day_of_week))==0)
      {
         flatten=true;
         why="inactive weekday";
         return false;
      }

      if(!AxHours(t.hour,StartHour,EndHour))
      {
         why="outside entry hours";
         return false;
      }

      if(ExcludeStartHour!=ExcludeEndHour &&
         AxHours(t.hour,ExcludeStartHour,ExcludeEndHour))
      {
         why="excluded entry hours";
         return false;
      }

      if(!BrokerSession())
      {
         why="broker session closed";
         return false;
      }
      return true;
   }

   bool Killed()
   {
      // Deliberately ignores the obsolete, unscoped AUREX_KILL.
      return Load(ap+"KILL2")>0.0;
   }

   void Persist()
   {
      if(!owns || day_key==0)
         return;

      GlobalVariableSet(Key("DAY2"),day_key);
      GlobalVariableSet(Key("TRADES2"),trades_today);
      GlobalVariableSet(Key("LOSSES2"),losses);
      GlobalVariableSet(Key("STREAK2"),streak_trip ? 1.0 : 0.0);
      GlobalVariableSet(Key("COOLDOWN2"),(double)cooldown_until);
      GlobalVariableSet(Key("EXIT2"),(double)last_exit_time);
   }

   void Daily()
   {
      int today=AxDate(Now());
      if(today==0 || today==day_key)
         return;

      Persist();
      day_key=today;
      trades_today=0;
      losses=0;
      streak_trip=false;
      cooldown_until=0;
      last_exit_time=0;
      ArrayResize(seen_positions,0);

      if((int)Load(Key("DAY2"))==day_key)
      {
         trades_today=(int)Load(Key("TRADES2"));
         losses=(int)Load(Key("LOSSES2"));
         streak_trip=Load(Key("STREAK2"))>0;
         cooldown_until=(datetime)Load(Key("COOLDOWN2"));
         last_exit_time=(datetime)Load(Key("EXIT2"));
      }

      string suffix=IntegerToString(day_key);
      string snapshot=ap+"EQ2_"+suffix;
      if(!GlobalVariableCheck(snapshot))
         GlobalVariableSet(snapshot,AccountInfoDouble(ACCOUNT_EQUITY));

      day_equity=Load(snapshot);
      loss_trip=Load(ap+"LOSS2_"+suffix)>0;
      profit_trip=Load(ap+"PROFIT2_"+suffix)>0;
      history_dirty=true;
      Persist();
      GlobalVariablesFlush();

      Log(1,"DAY_START",
          "equity="+DoubleToString(day_equity,2)+
          " trades="+IntegerToString(trades_today));

      // Do not clear execution faults merely because midnight passed.
   }

   void Circuit()
   {
      string suffix=IntegerToString(day_key);
      day_equity=Load(ap+"EQ2_"+suffix,day_equity);
      loss_trip=loss_trip || Load(ap+"LOSS2_"+suffix)>0;
      profit_trip=profit_trip || Load(ap+"PROFIT2_"+suffix)>0;

      double change=AccountInfoDouble(ACCOUNT_EQUITY)-day_equity;
      if(day_equity>0 &&
         change<=-day_equity*DailyLossLimitPercent/100.0)
      {
         if(!loss_trip)
            Log(0,"DAILY_LOSS_TRIP",
                "equity_change="+DoubleToString(change,2));
         loss_trip=true;
         GlobalVariableSet(ap+"LOSS2_"+suffix,1.0);
      }

      if(day_equity>0 && DailyProfitTargetPercent>0 &&
         change>=day_equity*DailyProfitTargetPercent/100.0)
      {
         profit_trip=true;
         GlobalVariableSet(ap+"PROFIT2_"+suffix,1.0);
      }

      if(Killed() || loss_trip || profit_trip || streak_trip)
         cancel_requested=true;

      if(Killed() || (loss_trip && CloseOnCircuitBreaker))
         flatten_requested=true;
   }
