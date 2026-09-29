#ifndef AUREX_ENGINE_MQH
#define AUREX_ENGINE_MQH

struct AxLive
{
   int orders;
   int positions;
   ulong buy_order;
   ulong sell_order;
   ulong keep_position;
   ulong extra_position;
   bool foreign_netting_position;
};

class AxEngine
{
private:
   AxProfile p;
   AxMarket md;
   AxLimiter limiter;

   AX_STATE state;
   string reason;
   string account_prefix;
   string instance_prefix;
   string object_prefix;

   ulong magic;
   bool eligible;
   bool is_gold;
   bool is_btc;
   bool connected;
   bool hedging;
   bool initialized;

   int day_key;
   double day_start_equity;
   bool loss_trip;
   bool profit_trip;
   int trades_today;
   int consecutive_losses;
   int double_fills;
   double extra_delta;

   double slip_ewma;
   int slip_samples;
   double observed_commission;
   int commission_samples;

   datetime cooldown_until;
   ulong last_reconcile;
   ulong last_panel;
   ulong last_atr;
   ulong last_profile;
   ulong last_heartbeat;
   ulong last_buy_modify;
   ulong last_sell_modify;
   ulong last_trail;
   ulong retry_after;
   ulong quarantine_until;

   bool busy;
   uint busy_request;
   ulong busy_since;
   bool busy_async;
   bool dirty;
   bool cancel_all;
   bool force_flat;
   bool virtual_armed;
   bool restoring;
   bool hard_pause;

   double virtual_buy;
   double virtual_sell;
   int virtual_buy_hits;
   int virtual_sell_hits;

   ulong cycle_buy;
   ulong cycle_sell;
   ulong first_fill_order;

   double last_market_reference;
   double last_trigger_spread;
   datetime last_reference_time;

   AxCosts costs;
   AxGeometry geometry;

   double latency[128];
   int latency_count;
   int latency_next;
   string latency_kind;

   double owner_stamp;
   bool own_lock;

   ulong last_counted_position;
   ulong close_candidate;
   ulong close_candidate_since;

   string last_log_reason;

   datetime Now()
   {
      datetime t=TimeCurrent();
      if(t<=0)
         t=TimeTradeServer();
      return t;
   }

   string Key(const string suffix)
   {
      return instance_prefix+suffix;
   }

   double Load(const string key,const double fallback)
   {
      if(GlobalVariableCheck(key))
         return GlobalVariableGet(key);
      return fallback;
   }

   void Log(const int level,const string event,const string detail)
   {
      if(level<=LogLevel)
         Print("AUREX event=",event,
               " symbol=",_Symbol,
               " magic=",magic,
               " state=",AxStateName(state),
               " ",detail);
   }

   void SetState(const AX_STATE next,const string why)
   {
      state=next;
      reason=why;

      string signature=AxStateName(next)+"|"+why;
      if(signature!=last_log_reason)
      {
         Log(1,"STATE","reason="+why);
         last_log_reason=signature;
      }
   }

   bool Invalid(const string name,const string why)
   {
      Print("AUREX invalid_parameter=",name," reason=",why);
      return false;
   }

   bool Validate()
   {
      if(MagicNumberGold==0 || MagicNumberBtc==0 ||
         MagicNumberGold==MagicNumberBtc)
         return Invalid("MagicNumberGold/MagicNumberBtc",
                        "must be nonzero and distinct");

      if((int)ExecutionMode<0 || (int)ExecutionMode>1)
         return Invalid("ExecutionMode","invalid enum");

      if((int)LotSizingMode<0 || (int)LotSizingMode>3)
         return Invalid("LotSizingMode","invalid enum");

      if(Slippage<0 || CommissionPerLotRoundTurn<0.0)
         return Invalid("Slippage/CommissionPerLotRoundTurn",
                        "must not be negative");

      if(TradeGoldDays<0 || TradeGoldDays>127 ||
         TradeBtcDays<0 || TradeBtcDays>127)
         return Invalid("TradeGoldDays/TradeBtcDays","use seven-bit masks");

      if(StartHour<0 || StartHour>23 || EndHour<0 || EndHour>24 ||
         ExcludeStartHour<0 || ExcludeStartHour>23 ||
         ExcludeEndHour<0 || ExcludeEndHour>24 ||
         FridayCloseHour<0 || FridayCloseHour>24 ||
         SundayCloseHour<0 || SundayCloseHour>24)
         return Invalid("Schedule hours","outside supported hour range");

      if(FixedLot<=0.0 || RiskPercent<=0.0 || RiskPercent>10.0 ||
         MaxLot<=0.0 || MarginBufferPercent<0.0 ||
         MarginBufferPercent>=100.0)
         return Invalid("Position Sizing","invalid lot/risk/margin limit");

      if(DailyLossLimitPercent<=0.0 || DailyLossLimitPercent>100.0 ||
         DailyProfitTargetPercent<0.0 ||
         MaxTradesPerDay<1 || MaxConsecutiveLosses<1 ||
         MaxCostToRiskRatio<=0.0 || MaxDoubleFillsPerDay<0)
         return Invalid("Risk Control","invalid daily or cost limit");

      if(DeltaPoints<=0.0 || MaxDistancePoints<=0.0 ||
         RecentreMinMs<50 || StopPoints<=0.0 || TpMultiplier<0.0 ||
         MinNetTargetPoints<0.0 || MaxSpreadPoints<1 ||
         SpreadStableMs<0 || MaxQuoteAgeMs<50)
         return Invalid("Order Geometry","invalid distance or interval");

      if(AtrPeriod<2 || MinAtrPoints<0.0 ||
         MaxAtrPoints<=MinAtrPoints ||
         CooldownAfterWinSecs<0 || CooldownAfterLossSecs<0 ||
         VirtualTriggerConfirmTicks<1)
         return Invalid("Volatility Gate","invalid bounds or confirmation");

      if(TslTriggerPoints<0.0 || TslPoints<=0.0 ||
         TslStepPoints<=0.0 || TslMinIntervalMs<50 ||
         BreakEvenAtPoints<0.0)
         return Invalid("Trailing","invalid distance or interval");

      if(MaxRequestsPerSecond<=0.0 || BurstRequests<3 ||
         ReconcileIntervalSecs<1 || LogLevel<0 || LogLevel>3)
         return Invalid("Traffic & Telemetry","invalid rate/burst/log setting");

      return true;
   }

   void ResolveSymbol()
   {
      string upper=_Symbol;
      StringToUpper(upper);

      if(GoldSymbol!="")
         is_gold=(_Symbol==GoldSymbol);
      else
         is_gold=(StringFind(upper,"XAUUSD")>=0 ||
                  StringFind(upper,"GOLD")>=0);

      if(BtcSymbol!="")
         is_btc=(_Symbol==BtcSymbol);
      else
         is_btc=(StringFind(upper,"BTCUSD")>=0);

      if(is_gold && is_btc)
      {
         is_gold=false;
         is_btc=false;
      }

      eligible=is_gold || is_btc;
      magic=is_btc ? MagicNumberBtc : MagicNumberGold;
   }

   bool AcquireOwner()
   {
      if(!eligible)
         return true;

      string k=Key("OWNER");
      double current=Load(k,0.0);
      double now=(double)TimeLocal();

      if(current>now-15.0 && current<=now+15.0)
         return false;

      if(!GlobalVariableCheck(k))
         GlobalVariableSet(k,0.0);

      owner_stamp=now;
      if(!GlobalVariableSetOnCondition(k,owner_stamp,current))
         return false;

      own_lock=true;
      return true;
   }

   void Heartbeat()
   {
      ulong now=GetTickCount64();
      if(now-last_heartbeat<1000)
         return;

      last_heartbeat=now;

      if(own_lock)
      {
         double next=(double)TimeLocal();
         if(!GlobalVariableSetOnCondition(Key("OWNER"),next,owner_stamp))
         {
            own_lock=false;
            hard_pause=true;
            SetState(AX_PAUSED,"instance owner lock lost");
         }
         else
            owner_stamp=next;
      }

      GlobalVariableSet(Key("ACTIVE"),(double)Now());
   }

   void Persist()
   {
      if(!eligible)
         return;

      GlobalVariableSet(Key("DAY"),day_key);
      GlobalVariableSet(Key("TRADES"),trades_today);
      GlobalVariableSet(Key("LOSSES"),consecutive_losses);
      GlobalVariableSet(Key("RACES"),double_fills);
      GlobalVariableSet(Key("EXTRA_DELTA"),extra_delta);
      GlobalVariableSet(Key("COOLDOWN"),(double)cooldown_until);
      GlobalVariableSet(Key("SLIP"),slip_ewma);
      GlobalVariableSet(Key("SLIP_N"),slip_samples);
      GlobalVariableSet(Key("COMM"),observed_commission);
      GlobalVariableSet(Key("COMM_N"),commission_samples);
      GlobalVariableSet(Key("LAST_POS"),(double)last_counted_position);
      GlobalVariablesFlush();
   }

   void Daily()
   {
      int current=AxDateKey(Now());
      if(current==day_key && day_start_equity>0.0)
         return;

      bool first=(day_key==0);
      day_key=current;

      string day=account_prefix+"DAYSTART_"+IntegerToString(day_key);

      // Terminal globals offer no atomic create-if-absent primitive.
      // Re-read the shared value on every timer pass below.
      if(!GlobalVariableCheck(day))
         GlobalVariableSet(day,AccountInfoDouble(ACCOUNT_EQUITY));

      day_start_equity=GlobalVariableGet(day);
      if(day_start_equity<=0.0)
         day_start_equity=AccountInfoDouble(ACCOUNT_EQUITY);

      int saved=(int)Load(Key("DAY"),0.0);
      if(first && saved==day_key)
      {
         trades_today=(int)Load(Key("TRADES"),0.0);
         consecutive_losses=(int)Load(Key("LOSSES"),0.0);
         double_fills=(int)Load(Key("RACES"),0.0);
         extra_delta=Load(Key("EXTRA_DELTA"),0.0);
         cooldown_until=(datetime)Load(Key("COOLDOWN"),0.0);
         last_counted_position=(ulong)Load(Key("LAST_POS"),0.0);
      }
      else
      {
         trades_today=0;
         consecutive_losses=0;
         double_fills=0;
         extra_delta=0.0;
         cooldown_until=0;
         last_counted_position=0;
      }

      loss_trip=Load(account_prefix+"LOSS_"+IntegerToString(day_key),0)>0;
      profit_trip=Load(account_prefix+"PROFIT_"+IntegerToString(day_key),0)>0;

      hard_pause=false;
      dirty=true;
      Persist();

      Log(1,"DAY_START",
          "equity="+DoubleToString(day_start_equity,2));
   }

   bool KillActive()
   {
      return Load("AUREX_KILL",0)>0.0 ||
             Load(account_prefix+"KILL",0)>0.0;
   }

   bool Schedule(string &why,bool &flatten)
   {
      flatten=false;

      if(!eligible)
      {
         why="unsupported chart symbol";
         return false;
      }

      MqlDateTime t;
      TimeToStruct(Now(),t);

      if(is_gold && t.day_of_week==5 && t.hour>=FridayCloseHour)
      {
         flatten=true;
         why="Friday gold flatten";
         return false;
      }

      if(is_btc && t.day_of_week==0 && t.hour>=SundayCloseHour)
      {
         flatten=true;
         why="Sunday BTC flatten";
         return false;
      }

      int mask=is_btc ? TradeBtcDays : TradeGoldDays;

      if((mask & (1<<t.day_of_week))==0)
      {
         flatten=true;
         why="inactive weekday";
         return false;
      }

      if(!AxHourWindow(t.hour,StartHour,EndHour))
      {
         why="outside configured session";
         return false;
      }

      if(ExcludeStartHour!=ExcludeEndHour &&
         AxHourWindow(t.hour,ExcludeStartHour,ExcludeEndHour))
      {
         why="exclude window";
         return false;
      }

      if(!p.SessionOpen(Now()))
      {
         why="broker session closed or unavailable";
         return false;
      }

      why="";
      return true;
   }

   void Scan(AxLive &live)
   {
      ZeroMemory(live);
      long oldest=0;

      for(int i=OrdersTotal()-1;i>=0;i--)
      {
         ulong ticket=OrderGetTicket(i);
         if(ticket==0 ||
            OrderGetString(ORDER_SYMBOL)!=_Symbol ||
            (ulong)OrderGetInteger(ORDER_MAGIC)!=magic)
            continue;

         live.orders++;

         ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type==ORDER_TYPE_BUY_STOP)
            live.buy_order=ticket;
         if(type==ORDER_TYPE_SELL_STOP)
            live.sell_order=ticket;
      }

      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol)
            continue;

         if((ulong)PositionGetInteger(POSITION_MAGIC)!=magic)
         {
            if(!hedging)
               live.foreign_netting_position=true;
            continue;
         }

         live.positions++;
         long created=PositionGetInteger(POSITION_TIME_MSC);

         if(live.keep_position==0 || created<oldest)
         {
            if(live.keep_position!=0)
               live.extra_position=live.keep_position;

            live.keep_position=ticket;
            oldest=created;
         }
         else
            live.extra_position=ticket;
      }
   }

   bool PositionIdOpen(const ulong identifier)
   {
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(PositionGetTicket(i)==0)
            continue;

         if((ulong)PositionGetInteger(POSITION_IDENTIFIER)==identifier)
            return true;
      }
      return false;
   }

   void Circuit()
   {
      string day=IntegerToString(day_key);
      day_start_equity=Load(account_prefix+"DAYSTART_"+day,day_start_equity);
      loss_trip=loss_trip || Load(account_prefix+"LOSS_"+day,0)>0;
      profit_trip=profit_trip || Load(account_prefix+"PROFIT_"+day,0)>0;

      double pnl=AccountInfoDouble(ACCOUNT_EQUITY)-day_start_equity;

      if(day_start_equity>0.0 &&
         pnl<=-day_start_equity*DailyLossLimitPercent/100.0)
      {
         if(!loss_trip)
            Log(0,"DAILY_LOSS_TRIP","pnl="+DoubleToString(pnl,2));

         loss_trip=true;
         GlobalVariableSet(account_prefix+"LOSS_"+day,1.0);
      }

      if(DailyProfitTargetPercent>0.0 && day_start_equity>0.0 &&
         pnl>=day_start_equity*DailyProfitTargetPercent/100.0)
      {
         profit_trip=true;
         GlobalVariableSet(account_prefix+"PROFIT_"+day,1.0);
      }

      if(KillActive() || loss_trip || profit_trip)
      {
         virtual_armed=false;
         cancel_all=true;

         // Kill always requests flattening. Profit lock does not.
         if(KillActive() || (loss_trip && CloseOnCircuitBreaker))
            force_flat=true;

         SetState(AX_HALTED,
                  KillActive() ? "kill switch" :
                  (loss_trip ? "daily loss circuit" : "daily profit lock"));
      }
   }

   void BuildGeometry()
   {
      p.RefreshDistances();

      // One tick of geometric safety beyond the reported stop boundary.
      double safety=p.tick_size/p.point;
      double minimum=(double)p.stops+safety;

      geometry.delta_points=MathMax(DeltaPoints+extra_delta,minimum);
      geometry.stop_points=MathMax(StopPoints,minimum);

      double d=geometry.delta_points*p.point;
      double s=geometry.stop_points*p.point;
      double tp=geometry.stop_points*TpMultiplier*p.point;

      geometry.buy=NormalizeDouble(AxRoundUp(md.tick.ask+d,p.tick_size),p.digits);
      geometry.sell=NormalizeDouble(AxRoundDown(md.tick.bid-d,p.tick_size),p.digits);

      geometry.buy_sl=NormalizeDouble(AxRoundDown(geometry.buy-s,p.tick_size),p.digits);
      geometry.sell_sl=NormalizeDouble(AxRoundUp(geometry.sell+s,p.tick_size),p.digits);

      geometry.buy_tp=0.0;
      geometry.sell_tp=0.0;

      if(TpMultiplier>0.0)
      {
         tp=MathMax(tp,minimum*p.point);
         geometry.buy_tp=NormalizeDouble(AxRoundUp(geometry.buy+tp,p.tick_size),p.digits);
         geometry.sell_tp=NormalizeDouble(AxRoundDown(geometry.sell-tp,p.tick_size),p.digits);
      }
   }

   double ExpectedSlip()
   {
      // Beta seed: 10 points. EWMA replaces it only after 10 samples.
      return slip_samples>=10 ? MathMax(0.0,slip_ewma) : 10.0;
   }

   double EffectiveCommission()
   {
      // Do not lower the cost assumption merely because entry commission
      // is zero or the broker books commission later.
      return MathMax(CommissionPerLotRoundTurn,
                     commission_samples>0 ? observed_commission : 0.0);
   }

   bool ComputeCosts(string &why)
   {
      ZeroMemory(costs);

      double pv=p.LossPointValue();
      if(pv<=0.0)
      {
         why="tick value unavailable";
         return false;
      }

      double commission=EffectiveCommission();
      costs.point_value=pv;
      costs.commission_points=commission/pv;
      costs.round_turn_points=md.Median()+costs.commission_points+
                              2.0*ExpectedSlip();

      double base=AccountInfoDouble(ACCOUNT_BALANCE);
      if(LotSizingMode==PCT_EQUITY)
         base=AccountInfoDouble(ACCOUNT_EQUITY);
      if(LotSizingMode==PCT_FREE_MARGIN)
         base=AccountInfoDouble(ACCOUNT_MARGIN_FREE);

      costs.risk_money=base*RiskPercent/100.0;

      // Allow for outward tick rounding of protective stops.
      double risk_points=geometry.stop_points+ExpectedSlip()+
                         2.0*p.tick_size/p.point;
      double denominator=risk_points*pv+commission;

      if(costs.risk_money<=0.0 || denominator<=0.0)
      {
         why="risk budget unavailable";
         return false;
      }

      double lots=(LotSizingMode==FIXED) ?
                   FixedLot : costs.risk_money/denominator;

      lots=MathMin(lots,MathMin(MaxLot,p.volume_max));
      lots=AxFloorVolume(lots,p.volume_step);

      if(lots<p.volume_min-1e-9)
      {
         why="risk-sized lot below broker minimum";
         return false;
      }

      double buy_margin=0.0,sell_margin=0.0;

      if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,lots,md.tick.ask,buy_margin) ||
         !OrderCalcMargin(ORDER_TYPE_SELL,_Symbol,lots,md.tick.bid,sell_margin))
      {
         why="OrderCalcMargin unavailable";
         return false;
      }

      // Conservative: reserve both sides even if broker would offset.
      double margin=buy_margin+sell_margin;
      double available=AccountInfoDouble(ACCOUNT_MARGIN_FREE)*
                       (1.0-MarginBufferPercent/100.0);

      if(margin>available && margin>0.0)
         lots=AxFloorVolume(lots*available/margin,p.volume_step);

      if(lots<p.volume_min-1e-9)
      {
         why="margin-sized lot below broker minimum";
         return false;
      }

      costs.lots=lots;
      costs.cash_cost=costs.round_turn_points*pv*lots;
      costs.ratio=costs.cash_cost/costs.risk_money;

      if(costs.ratio>MaxCostToRiskRatio)
      {
         why="cost-to-risk gate";
         return false;
      }

      if(TpMultiplier>0.0 &&
         geometry.stop_points*TpMultiplier-costs.round_turn_points<
         MinNetTargetPoints)
      {
         why="TP below minimum after-cost target";
         return false;
      }

      // With no TP, use the trailing activation as the nominal target.
      if(TpMultiplier==0.0 &&
         TslTriggerPoints-costs.round_turn_points<MinNetTargetPoints)
      {
         why="trailing activation below after-cost target";
         return false;
      }

      return true;
   }

   bool EntryGate(string &why)
   {
      if(!eligible)
      {
         why="unsupported chart symbol";
         return false;
      }

      if(!own_lock)
      {
         why="duplicate instance or owner lock lost";
         return false;
      }

      if(AccountInfoString(ACCOUNT_CURRENCY)!="USD")
      {
         why="beta requires USD account";
         return false;
      }

      if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      {
         why="disconnected";
         return false;
      }

      if(!MQLInfoInteger(MQL_TRADE_ALLOWED) ||
         !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
         !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
         !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      {
         why="automated trading not permitted";
         return false;
      }

      if(loss_trip || profit_trip || KillActive())
      {
         why="daily halt or kill";
         return false;
      }

      if(hard_pause)
      {
         why="execution paused; inspect journal and reattach";
         return false;
      }

      if(GetTickCount64()<retry_after ||
         GetTickCount64()<quarantine_until)
      {
         why="execution backoff or reconciliation quarantine";
         return false;
      }

      bool flatten=false;
      if(!Schedule(why,flatten))
         return false;

      p.RefreshDistances();

      if(p.trade_mode!=SYMBOL_TRADE_MODE_FULL)
      {
         why="symbol does not permit both directions";
         return false;
      }

      if(ExecutionMode==SERVER_PENDING && !p.StopOrdersAllowed())
      {
         why="broker does not support stop orders with SL";
         return false;
      }

      if((p.order_mode & SYMBOL_ORDER_SL)==0 ||
         (TpMultiplier>0.0 && (p.order_mode & SYMBOL_ORDER_TP)==0))
      {
         why="required protective order type unavailable";
         return false;
      }

      if(ExecutionMode==SERVER_PENDING &&
         (p.expiration_mode & SYMBOL_EXPIRATION_GTC)==0)
      {
         why="GTC pending orders unsupported";
         return false;
      }

      if(md.QuoteAgeMs()>MaxQuoteAgeMs)
      {
         why="stale quote";
         return false;
      }

      if(md.spread>MaxSpreadPoints || !md.Stable(SpreadStableMs))
      {
         why="spread high or not stable";
         return false;
      }

      if(md.atr_points<MinAtrPoints || md.atr_points>MaxAtrPoints)
      {
         why="ATR outside gate or warming up";
         return false;
      }

      if(trades_today>=MaxTradesPerDay)
      {
         why="daily trade limit";
         return false;
      }

      if(consecutive_losses>=MaxConsecutiveLosses)
      {
         why="consecutive-loss limit";
         return false;
      }

      if(Now()<cooldown_until)
      {
         why="cooldown";
         return false;
      }

      AxLive live;
      Scan(live);
      if(live.foreign_netting_position)
      {
         why="foreign position on netting symbol";
         return false;
      }

      // Netting accounts cannot safely share the symbol with another EA.
      if(!hedging)
      {
         for(int i=OrdersTotal()-1;i>=0;i--)
         {
            if(OrderGetTicket(i)==0)
               continue;
            if(OrderGetString(ORDER_SYMBOL)==_Symbol &&
               (ulong)OrderGetInteger(ORDER_MAGIC)!=magic)
            {
               why="foreign pending order on netting symbol";
               return false;
            }
         }
      }

      BuildGeometry();
      return ComputeCosts(why);
   }

   void RequestBase(MqlTradeRequest &r,
                    const ENUM_TRADE_REQUEST_ACTIONS action,
                    const string side)
   {
      ZeroMemory(r);
      r.action=action;
      r.symbol=_Symbol;
      r.magic=magic;
      r.deviation=(ulong)Slippage;
      r.type_time=ORDER_TIME_GTC;
      r.type_filling=(action==TRADE_ACTION_PENDING ||
                      action==TRADE_ACTION_MODIFY) ?
                      ORDER_FILLING_RETURN : p.MarketFilling();
      r.comment="AUREX1|"+AxStateName(state)+"|"+side;
   }

   void LatencyAdd(const ulong microseconds,const string kind)
   {
      latency[latency_next]=(double)microseconds/1000.0;
      latency_next=(latency_next+1)%128;
      if(latency_count<128)
         latency_count++;
      latency_kind=kind;
   }

   double LatencyPercentile(const double fraction)
   {
      if(latency_count==0)
         return 0.0;

      double v[];
      ArrayResize(v,latency_count);
      for(int i=0;i<latency_count;i++)
         v[i]=latency[i];

      ArraySort(v);
      return v[(int)MathFloor((latency_count-1)*fraction)];
   }

   bool Accepted(const uint retcode)
   {
      return retcode==TRADE_RETCODE_DONE ||
             retcode==TRADE_RETCODE_PLACED ||
             retcode==TRADE_RETCODE_DONE_PARTIAL;
   }

   void Retcode(const uint code,const string comment)
   {
      switch(code)
      {
         case TRADE_RETCODE_DONE:
         case TRADE_RETCODE_PLACED:
         case TRADE_RETCODE_DONE_PARTIAL:
            dirty=true;
            break;

         case TRADE_RETCODE_REQUOTE:
         case TRADE_RETCODE_PRICE_CHANGED:
         case TRADE_RETCODE_PRICE_OFF:
            retry_after=GetTickCount64()+100;
            dirty=true;
            break;

         case TRADE_RETCODE_INVALID_STOPS:
         case TRADE_RETCODE_INVALID_PRICE:
            p.Refresh(_Symbol);
            retry_after=GetTickCount64()+250;
            dirty=true;
            break;

         case TRADE_RETCODE_FROZEN:
            retry_after=GetTickCount64()+250;
            dirty=true;
            break;

         case TRADE_RETCODE_TOO_MANY_REQUESTS:
            limiter.Penalize();
            retry_after=GetTickCount64()+200;
            dirty=true;
            break;

         case TRADE_RETCODE_NO_MONEY:
            retry_after=GetTickCount64()+2000;
            SetState(AX_PAUSED,"broker margin rejection");
            break;

         case TRADE_RETCODE_MARKET_CLOSED:
         case TRADE_RETCODE_TRADE_DISABLED:
            retry_after=GetTickCount64()+5000;
            SetState(AX_PAUSED,"market closed or trading disabled");
            break;

         case TRADE_RETCODE_CONNECTION:
         case TRADE_RETCODE_TIMEOUT:
            quarantine_until=GetTickCount64()+30000;
            cancel_all=true;
            dirty=true;
            SetState(AX_RECONCILING,"ambiguous execution result");
            break;

         default:
            hard_pause=true;
            cancel_all=true;
            SetState(AX_PAUSED,"unhandled broker response");
            break;
      }

      if(!Accepted(code))
         Log(0,"REQUEST_RESULT",
             "retcode="+IntegerToString((int)code)+" comment="+comment);
   }

   bool Send(MqlTradeRequest &r,const bool asynchronous,
             const bool maintenance,MqlTradeResult &result)
   {
      ZeroMemory(result);

      if(!TerminalInfoInteger(TERMINAL_CONNECTED))
         return false;

      if(GetTickCount64()<retry_after)
         return false;

      bool opens=(r.action==TRADE_ACTION_PENDING ||
                  (r.action==TRADE_ACTION_DEAL && r.position==0));

      if(opens)
      {
         double margin=0.0;
         ENUM_ORDER_TYPE side=
            (r.type==ORDER_TYPE_BUY || r.type==ORDER_TYPE_BUY_STOP) ?
            ORDER_TYPE_BUY : ORDER_TYPE_SELL;

         if(!OrderCalcMargin(side,_Symbol,r.volume,r.price,margin))
            return false;

         double available=AccountInfoDouble(ACCOUNT_MARGIN_FREE)*
                          (1.0-MarginBufferPercent/100.0);

         if(margin>available)
         {
            SetState(AX_PAUSED,"pre-send margin buffer");
            return false;
         }
      }

      MqlTradeCheckResult check;
      ZeroMemory(check);
      ResetLastError();

      if(!OrderCheck(r,check))
      {
         Log(0,"ORDER_CHECK_FAILED",
             "action="+IntegerToString((int)r.action)+
             " type="+IntegerToString((int)r.type)+
             " volume="+DoubleToString(r.volume,8)+
             " price="+DoubleToString(r.price,p.digits)+
             " sl="+DoubleToString(r.sl,p.digits)+
             " tp="+DoubleToString(r.tp,p.digits)+
             " retcode="+IntegerToString((int)check.retcode)+
             " error="+IntegerToString(GetLastError())+
             " comment="+check.comment);

         Retcode(check.retcode,check.comment);
         return false;
      }

      if(!limiter.Take(maintenance))
         return false;

      ulong begin=GetMicrosecondCount();
      bool sent=asynchronous ? OrderSendAsync(r,result) : OrderSend(r,result);
      ulong elapsed=GetMicrosecondCount()-begin;

      LatencyAdd(elapsed,EnumToString(r.action));

      Log(2,"SEND",
          "action="+EnumToString(r.action)+
          " order="+(string)r.order+
          " position="+(string)r.position+
          " volume="+DoubleToString(r.volume,8)+
          " price="+DoubleToString(r.price,p.digits)+
          " sl="+DoubleToString(r.sl,p.digits)+
          " tp="+DoubleToString(r.tp,p.digits)+
          " retcode="+IntegerToString((int)result.retcode)+
          " request_id="+IntegerToString((int)result.request_id)+
          " send_ms="+DoubleToString((double)elapsed/1000.0,3));

      Retcode(result.retcode,result.comment);

      if(!sent || !Accepted(result.retcode))
         return false;

      dirty=true;

      if(asynchronous || r.action==TRADE_ACTION_DEAL)
      {
         busy=true;
         busy_async=asynchronous;
         busy_request=result.request_id;
         busy_since=GetTickCount64();
      }

      return true;
   }

   bool FrozenOrder(const ulong ticket)
   {
      p.RefreshDistances();
      if(!OrderSelect(ticket))
         return true;

      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double price=OrderGetDouble(ORDER_PRICE_OPEN);
      double distance=0.0;

      if(type==ORDER_TYPE_BUY_STOP)
         distance=(price-md.tick.ask)/p.point;
      else if(type==ORDER_TYPE_SELL_STOP)
         distance=(md.tick.bid-price)/p.point;
      else
         return false;

      return distance<=(double)p.freeze+p.tick_size/p.point;
   }

   bool RemoveOrder(const ulong ticket)
   {
      if(ticket==0 || !OrderSelect(ticket))
         return true;

      if(FrozenOrder(ticket))
         return false;

      MqlTradeRequest r;
      MqlTradeResult result;
      RequestBase(r,TRADE_ACTION_REMOVE,"CANCEL");
      r.order=ticket;

      return Send(r,false,true,result);
   }

   void CancelPendings()
   {
      // Bounded by the number of broker orders, never a waiting loop.
      for(int i=OrdersTotal()-1;i>=0;i--)
      {
         ulong ticket=OrderGetTicket(i);
         if(ticket==0 ||
            OrderGetString(ORDER_SYMBOL)!=_Symbol ||
            (ulong)OrderGetInteger(ORDER_MAGIC)!=magic)
            continue;

         RemoveOrder(ticket);
      }
   }

   bool ClosePosition(const ulong ticket,const string why)
   {
      if(ticket==0 || !PositionSelectByTicket(ticket))
         return false;

      if(md.QuoteAgeMs()>MaxQuoteAgeMs)
      {
         Log(0,"STALE_HOLD","close_reason="+why);
         return false;
      }

      ENUM_POSITION_TYPE type=
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      MqlTradeRequest r;
      MqlTradeResult result;
      RequestBase(r,TRADE_ACTION_DEAL,"CLOSE");

      r.position=ticket;
      r.volume=PositionGetDouble(POSITION_VOLUME);
      r.type=type==POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      r.price=type==POSITION_TYPE_BUY ? md.tick.bid : md.tick.ask;

      return Send(r,false,true,result);
   }

   void Reconcile()
   {
      AxLive live;
      Scan(live);
      last_reconcile=GetTickCount64();
      dirty=false;

      if(live.foreign_netting_position)
      {
         cancel_all=true;
         virtual_armed=false;
         SetState(AX_PAUSED,"foreign netting position; no ownership assumed");
         return;
      }

      if(live.positions>1)
      {
         cancel_all=true;
         virtual_armed=false;
         SetState(AX_RECONCILING,"multiple managed positions; cleanup queued");
         return;
      }

      if(live.positions==1)
      {
         if(live.orders>0)
            cancel_all=true;

         virtual_armed=false;

         if(!loss_trip && !profit_trip && !KillActive())
            SetState(AX_IN_POSITION,"managed position present");
         return;
      }

      if(busy || GetTickCount64()<quarantine_until)
      {
         SetState(AX_RECONCILING,"awaiting request resolution");
         return;
      }

      if(cancel_all && live.orders==0)
         cancel_all=false;

      if(force_flat && live.positions==0)
         force_flat=false;

      if(loss_trip || profit_trip || KillActive())
      {
         SetState(AX_HALTED,"daily halt or kill");
         return;
      }

      if(live.orders==2 && live.buy_order!=0 && live.sell_order!=0 &&
         ExecutionMode==SERVER_PENDING && !cancel_all)
      {
         cycle_buy=live.buy_order;
         cycle_sell=live.sell_order;
         SetState(AX_ARMED,"server straddle reconciled");
         return;
      }

      if(live.orders!=0)
      {
         cancel_all=true;
         virtual_armed=false;
         SetState(AX_RECONCILING,"orphan or unexpected pending orders");
         Log(0,"RECONCILE_ANOMALY",
             "orders="+IntegerToString(live.orders));
         return;
      }

      if(virtual_armed)
      {
         SetState(AX_ARMED,"virtual straddle");
         return;
      }

      if(Now()<cooldown_until)
         SetState(AX_COOLDOWN,"exit cooldown");
      else
         SetState(AX_IDLE,"flat and reconciled");
   }

   void Arm()
   {
      if(busy || cancel_all || force_flat ||
         GetTickCount64()<quarantine_until)
         return;

      AxLive live;
      Scan(live);

      if(live.orders!=0 || live.positions!=0)
      {
         dirty=true;
         return;
      }

      first_fill_order=0;
      cycle_buy=0;
      cycle_sell=0;
      virtual_buy_hits=0;
      virtual_sell_hits=0;

      if(ExecutionMode==VIRTUAL_STOPS)
      {
         virtual_buy=geometry.buy;
         virtual_sell=geometry.sell;
         virtual_armed=true;
         SetState(AX_ARMED,"virtual straddle armed");
         return;
      }

      MqlTradeRequest buy,sell;
      MqlTradeResult buy_result,sell_result;

      RequestBase(buy,TRADE_ACTION_PENDING,"BUY");
      buy.type=ORDER_TYPE_BUY_STOP;
      buy.volume=costs.lots;
      buy.price=geometry.buy;
      buy.sl=geometry.buy_sl;
      buy.tp=geometry.buy_tp;

      RequestBase(sell,TRADE_ACTION_PENDING,"SELL");
      sell.type=ORDER_TYPE_SELL_STOP;
      sell.volume=costs.lots;
      sell.price=geometry.sell;
      sell.sl=geometry.sell_sl;
      sell.tp=geometry.sell_tp;

      // Both fully constructed requests are preflighted before placement.
      MqlTradeCheckResult check_buy,check_sell;
      ZeroMemory(check_buy);
      ZeroMemory(check_sell);

      if(!OrderCheck(buy,check_buy) || !OrderCheck(sell,check_sell))
      {
         retry_after=GetTickCount64()+1000;
         SetState(AX_PAUSED,"straddle pair preflight failed");
         return;
      }

      if(!Send(buy,false,false,buy_result))
         return;

      cycle_buy=buy_result.order;

      // A first leg can activate while the synchronous call is returning.
      // Do not place a second leg unless the first still exists as pending.
      AxLive after;
      Scan(after);

      if(cycle_buy==0 || !OrderSelect(cycle_buy) || after.positions>0)
      {
         cancel_all=true;
         dirty=true;
         SetState(AX_RECONCILING,"first leg changed during placement");
         return;
      }

      if(!Send(sell,false,false,sell_result))
      {
         cancel_all=true;
         RemoveOrder(cycle_buy);
         SetState(AX_RECONCILING,"second leg not accepted");
         return;
      }

      cycle_sell=sell_result.order;
      last_trigger_spread=md.spread;
      dirty=true;

      // Recognition of ARMED is through reconciliation/transactions.
      SetState(AX_RECONCILING,"straddle requests accepted");
   }

   void ModifySide(const ulong ticket,const bool buy_side)
   {
      if(ticket==0 || busy)
         return;

      ulong now=GetTickCount64();
      ulong last=buy_side ? last_buy_modify : last_sell_modify;

      if(now-last<(ulong)RecentreMinMs || !OrderSelect(ticket))
         return;

      double old=OrderGetDouble(ORDER_PRICE_OPEN);
      double distance=buy_side ?
         (old-md.tick.ask)/p.point : (md.tick.bid-old)/p.point;

      if(MathAbs(distance-geometry.delta_points)<=MaxDistancePoints)
         return;

      if(FrozenOrder(ticket))
         return;

      MqlTradeRequest r;
      MqlTradeResult result;
      RequestBase(r,TRADE_ACTION_MODIFY,buy_side ? "BUY" : "SELL");

      r.order=ticket;
      r.price=buy_side ? geometry.buy : geometry.sell;
      r.sl=buy_side ? geometry.buy_sl : geometry.sell_sl;
      r.tp=buy_side ? geometry.buy_tp : geometry.sell_tp;

      if(MathAbs(r.price-old)<p.tick_size*0.5)
         return;

      if(Send(r,true,false,result))
      {
         if(buy_side)
            last_buy_modify=now;
         else
            last_sell_modify=now;
      }
   }

   void Recentre()
   {
      if(busy)
         return;

      AxLive live;
      Scan(live);

      bool rising=(md.tick.bid+md.tick.ask)*0.5>=md.previous_mid;

      // One in-flight modification at a time. The approached side goes first.
      if(rising)
      {
         ModifySide(live.buy_order,true);
         if(!busy)
            ModifySide(live.sell_order,false);
      }
      else
      {
         ModifySide(live.sell_order,false);
         if(!busy)
            ModifySide(live.buy_order,true);
      }
   }

   void VirtualStep()
   {
      if(!virtual_armed || busy || !md.new_tick)
         return;

      bool crossed_buy=md.tick.ask>=virtual_buy;
      bool crossed_sell=md.tick.bid<=virtual_sell;

      virtual_buy_hits=crossed_buy ? virtual_buy_hits+1 : 0;
      virtual_sell_hits=crossed_sell ? virtual_sell_hits+1 : 0;

      bool fire_buy=virtual_buy_hits>=VirtualTriggerConfirmTicks;
      bool fire_sell=virtual_sell_hits>=VirtualTriggerConfirmTicks;

      if(fire_buy || fire_sell)
      {
         // Fresh spread and risk have already passed EntryGate.
         MqlTradeRequest r;
         MqlTradeResult result;
         RequestBase(r,TRADE_ACTION_DEAL,fire_buy ? "VBUY" : "VSELL");

         double minimum=((double)MathMax(p.stops,p.freeze)+
                         p.tick_size/p.point)*p.point;
         double stop=geometry.stop_points*p.point;
         double target=geometry.stop_points*TpMultiplier*p.point;

         r.type=fire_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         r.volume=costs.lots;
         r.price=fire_buy ? md.tick.ask : md.tick.bid;

         if(fire_buy)
         {
            r.sl=NormalizeDouble(AxRoundDown(
                 MathMin(r.price-stop,md.tick.bid-minimum),p.tick_size),p.digits);
            r.tp=TpMultiplier>0.0 ?
                 NormalizeDouble(AxRoundUp(
                 MathMax(r.price+target,md.tick.bid+minimum),p.tick_size),p.digits) : 0.0;
         }
         else
         {
            r.sl=NormalizeDouble(AxRoundUp(
                 MathMax(r.price+stop,md.tick.ask+minimum),p.tick_size),p.digits);
            r.tp=TpMultiplier>0.0 ?
                 NormalizeDouble(AxRoundDown(
                 MathMin(r.price-target,md.tick.ask-minimum),p.tick_size),p.digits) : 0.0;
         }

         // Re-size to the actual clamped market-entry stop distance.
         double actual_stop=MathAbs(r.price-r.sl)/p.point;
         if(LotSizingMode!=FIXED)
         {
            double unit_risk=(actual_stop+ExpectedSlip())*
                             costs.point_value+EffectiveCommission();
            r.volume=AxFloorVolume(
               MathMin(r.volume,costs.risk_money/unit_risk),p.volume_step);
         }

         virtual_armed=false;
         last_market_reference=r.price;
         last_trigger_spread=md.spread;
         last_reference_time=Now();

         if(r.volume<p.volume_min-1e-9)
         {
            SetState(AX_PAUSED,"virtual fill stop requires sub-minimum lot");
            return;
         }

         if(!Send(r,false,false,result))
         {
            dirty=true;
            SetState(AX_RECONCILING,"virtual entry not confirmed");
         }
         return;
      }

      // Hold a crossed trigger while awaiting consecutive confirmations.
      if(!crossed_buy && !crossed_sell)
      {
         virtual_buy=geometry.buy;
         virtual_sell=geometry.sell;
      }
   }

   void Trail(const ulong ticket)
   {
      if(busy || ticket==0 || !PositionSelectByTicket(ticket) ||
         md.QuoteAgeMs()>MaxQuoteAgeMs)
         return;

      ulong now=GetTickCount64();
      if(now-last_trail<(ulong)TslMinIntervalMs)
         return;

      p.RefreshDistances();

      ENUM_POSITION_TYPE type=
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool buy=type==POSITION_TYPE_BUY;

      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double old_sl=PositionGetDouble(POSITION_SL);
      double old_tp=PositionGetDouble(POSITION_TP);
      double market=buy ? md.tick.bid : md.tick.ask;
      double profit=(buy ? market-entry : entry-market)/p.point;
      double minimum=((double)MathMax(p.stops,p.freeze)+
                      p.tick_size/p.point)*p.point;

      double new_sl=old_sl;
      double new_tp=old_tp;

      // Repair missing protection after reconciliation or netting reversal.
      if(old_sl==0.0)
      {
         new_sl=buy ?
            MathMin(entry-StopPoints*p.point,market-minimum) :
            MathMax(entry+StopPoints*p.point,market+minimum);
      }

      double cost_points=md.Median()+
                         EffectiveCommission()/MathMax(p.LossPointValue(),1e-12)+
                         2.0*ExpectedSlip();

      if(BreakEvenAtPoints>0.0 && profit>=BreakEvenAtPoints)
      {
         double be=entry+(buy ? 1.0 : -1.0)*cost_points*p.point;
         if(buy)
            new_sl=MathMax(new_sl,be);
         else
            new_sl=(new_sl==0.0 ? be : MathMin(new_sl,be));
      }

      if(profit>=TslTriggerPoints)
      {
         double trail=market+(buy ? -1.0 : 1.0)*TslPoints*p.point;
         if(buy)
            new_sl=MathMax(new_sl,trail);
         else
            new_sl=(new_sl==0.0 ? trail : MathMin(new_sl,trail));
      }

      if(buy)
      {
         new_sl=AxRoundDown(MathMin(new_sl,market-minimum),p.tick_size);
         if(old_sl>0.0 && new_sl-old_sl<TslStepPoints*p.point)
            return;
      }
      else
      {
         new_sl=AxRoundUp(MathMax(new_sl,market+minimum),p.tick_size);
         if(old_sl>0.0 && old_sl-new_sl<TslStepPoints*p.point)
            return;
      }

      if(new_sl<=0.0)
         return;

      // Freeze restrictions may also apply to an existing TP.
      if(p.freeze>0 && old_tp>0.0 &&
         MathAbs(old_tp-market)<=p.freeze*p.point)
         return;

      if(old_tp==0.0 && TpMultiplier>0.0)
      {
         double distance=MathMax(StopPoints*TpMultiplier*p.point,minimum);
         new_tp=buy ? market+distance : market-distance;
         new_tp=buy ? AxRoundUp(new_tp,p.tick_size) :
                      AxRoundDown(new_tp,p.tick_size);
      }

      MqlTradeRequest r;
      MqlTradeResult result;
      RequestBase(r,TRADE_ACTION_SLTP,"PROTECT");
      r.position=ticket;
      r.sl=NormalizeDouble(new_sl,p.digits);
      r.tp=NormalizeDouble(new_tp,p.digits);

      if(Send(r,true,true,result))
         last_trail=now;
   }

   void Maintenance()
   {
      AxLive live;
      Scan(live);

      if(cancel_all || live.positions>0)
         CancelPendings();

      if(busy)
         return;

      if(live.positions>1 && live.extra_position!=0)
      {
         ClosePosition(live.extra_position,"double-fill cleanup");
         return;
      }

      if(force_flat && live.keep_position!=0)
      {
         ClosePosition(live.keep_position,"forced flatten");
         return;
      }

      if(live.keep_position!=0)
         Trail(live.keep_position);
   }

   void ObserveEntry(const ulong deal,const double reference,
                     const bool has_reference)
   {
      double fill=HistoryDealGetDouble(deal,DEAL_PRICE);
      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(deal,DEAL_TYPE);

      if(has_reference && p.point>0.0)
      {
         double signed_slip=(type==DEAL_TYPE_BUY ?
                             fill-reference : reference-fill)/p.point;
         double adverse=MathMax(0.0,signed_slip);

         slip_samples++;
         if(slip_samples==1)
            slip_ewma=adverse;
         else
            slip_ewma=0.90*slip_ewma+0.10*adverse;
      }

      ulong id=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      if(id!=last_counted_position)
      {
         last_counted_position=id;
         trades_today++;
      }

      Persist();
   }

   void FinalizeClosedPosition(const ulong id)
   {
      if(id==0 || PositionIdOpen(id))
         return;

      string finalized=Key("CLOSED_"+(string)id);
      if(GlobalVariableCheck(finalized))
         return;

      if(!HistorySelectByPosition(id))
         return;

      double pnl=0.0,commission=0.0,entry_volume=0.0;
      datetime last_exit=0;
      int total=HistoryDealsTotal();
      bool ours=false;
      bool has_exit=false;

      for(int i=0;i<total;i++)
      {
         ulong d=HistoryDealGetTicket(i);
         if(d==0)
            continue;

         if((ulong)HistoryDealGetInteger(d,DEAL_MAGIC)==magic)
            ours=true;

         pnl+=HistoryDealGetDouble(d,DEAL_PROFIT)+
              HistoryDealGetDouble(d,DEAL_SWAP)+
              HistoryDealGetDouble(d,DEAL_COMMISSION)+
              HistoryDealGetDouble(d,DEAL_FEE);

         commission+=MathAbs(HistoryDealGetDouble(d,DEAL_COMMISSION))+
                     MathAbs(HistoryDealGetDouble(d,DEAL_FEE));

         ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
         if(e==DEAL_ENTRY_IN)
            entry_volume+=HistoryDealGetDouble(d,DEAL_VOLUME);

         if(e==DEAL_ENTRY_OUT || e==DEAL_ENTRY_OUT_BY ||
            e==DEAL_ENTRY_INOUT)
         {
            has_exit=true;
            datetime t=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
            if(t>last_exit)
               last_exit=t;
         }
      }

      if(!ours || !has_exit)
         return;

      GlobalVariableSet(finalized,(double)Now());

      if(entry_volume>0.0)
      {
         double sample=commission/entry_volume;
         observed_commission=commission_samples==0 ? sample :
                             0.8*observed_commission+0.2*sample;
         commission_samples++;

         if(CommissionPerLotRoundTurn>0.0 &&
            MathAbs(observed_commission-CommissionPerLotRoundTurn)/
            CommissionPerLotRoundTurn>0.20)
            Log(0,"COMMISSION_MISMATCH",
                "observed="+DoubleToString(observed_commission,4)+
                " configured="+DoubleToString(CommissionPerLotRoundTurn,4));
      }

      if(AxDateKey(last_exit)==day_key)
      {
         consecutive_losses=pnl<0.0 ? consecutive_losses+1 : 0;
         cooldown_until=Now()+
            (pnl<0.0 ? CooldownAfterLossSecs : CooldownAfterWinSecs);
      }

      Log(1,"POSITION_FINAL",
          "position_id="+(string)id+
          " net="+DoubleToString(pnl,2)+
          " commission="+DoubleToString(commission,2));
      Persist();
   }

   // Continuation members are still private within AxEngine.
   bool market_ready;
   bool history_pending;
   ulong last_history_refresh;
   ulong last_stall_notice;
   ulong market_reference_order;

   ulong journal_deals[];
   double journal_refs[];
   double journal_spreads[];

   ulong reference_orders[];
   double reference_prices[];
   double reference_spreads[];

   ulong HashText(const string text)
   {
      ulong h=1469598103934665603;
      for(int i=0;i<StringLen(text);i++)
      {
         h^=(ulong)StringGetCharacter(text,i);
         h*=1099511628211;
      }
      return h;
   }

   void SaveTicket(const string suffix,const ulong ticket)
   {
      GlobalVariableSet(Key(suffix+"H"),(double)(ticket>>32));
      GlobalVariableSet(Key(suffix+"L"),
                        (double)(ticket & (ulong)0xFFFFFFFF));
   }

   ulong LoadTicket(const string suffix)
   {
      ulong hi=(ulong)Load(Key(suffix+"H"),0.0);
      ulong lo=(ulong)Load(Key(suffix+"L"),0.0);
      return (hi<<32)|lo;
   }

   bool BasicTests()
   {
      if(MathAbs(AxFloorVolume(0.019,0.01)-0.01)>1e-8)
         return false;
      if(AxFloorVolume(0.006,0.01)!=0.0)
         return false;
      if(MathAbs(AxRoundUp(100.011,0.01)-100.02)>1e-7)
         return false;
      if(MathAbs(AxRoundDown(100.019,0.01)-100.01)>1e-7)
         return false;
      if(MathAbs(AxFloorVolume(5.0/39.0,0.01)-0.12)>1e-8)
         return false;
      return AxHourWindow(23,22,2) &&
             AxHourWindow(1,22,2) &&
             !AxHourWindow(12,22,2);
   }

   bool ExtraValidation()
   {
      if(GoldSymbol!="" && GoldSymbol==BtcSymbol)
         return Invalid("GoldSymbol/BtcSymbol","must differ");

      if(FixedLot>MaxLot)
         return Invalid("FixedLot","must not exceed MaxLot");

      if(MaxCostToRiskRatio>1.0)
         return Invalid("MaxCostToRiskRatio","must not exceed 1");

      if(InitialSlippageEstimatePoints<0.0 ||
         !MathIsValidNumber(InitialSlippageEstimatePoints))
         return Invalid("InitialSlippageEstimatePoints","invalid estimate");

      if(QuoteStallCloseMs<MaxQuoteAgeMs)
         return Invalid("QuoteStallCloseMs","must be >= MaxQuoteAgeMs");

      if(VirtualTriggerConfirmTicks>100 ||
         MaxRequestsPerSecond>50.0 || BurstRequests>100.0 ||
         ReconcileIntervalSecs>3600)
         return Invalid("Beta bounds","confirmation/rate/interval too large");

      double values[]={
         CommissionPerLotRoundTurn,FixedLot,RiskPercent,
         MarginBufferPercent,MaxLot,DailyLossLimitPercent,
         DailyProfitTargetPercent,MaxCostToRiskRatio,DeltaPoints,
         MaxDistancePoints,StopPoints,TpMultiplier,MinNetTargetPoints,
         MinAtrPoints,MaxAtrPoints,TslTriggerPoints,TslPoints,
         TslStepPoints,BreakEvenAtPoints,MaxRequestsPerSecond,
         BurstRequests
      };
      for(int i=0;i<ArraySize(values);i++)
         if(!MathIsValidNumber(values[i]))
            return Invalid("Numeric input","NaN or infinity");
      return true;
   }

   void PutReference(const ulong order,const double price,
                     const double spread)
   {
      if(order==0 || price<=0.0)
         return;
      int n=ArraySize(reference_orders);
      for(int i=0;i<n;i++)
      {
         if(reference_orders[i]!=order)
            continue;
         reference_prices[i]=price;
         reference_spreads[i]=spread;
         return;
      }
      if(n>=256)
      {
         for(int i=1;i<n;i++)
         {
            reference_orders[i-1]=reference_orders[i];
            reference_prices[i-1]=reference_prices[i];
            reference_spreads[i-1]=reference_spreads[i];
         }
         n=255;
      }
      ArrayResize(reference_orders,n+1);
      ArrayResize(reference_prices,n+1);
      ArrayResize(reference_spreads,n+1);
      reference_orders[n]=order;
      reference_prices[n]=price;
      reference_spreads[n]=spread;
   }

   void DealReference(const ulong order,double &price,double &spread)
   {
      price=0.0;
      spread=-1.0;

      for(int i=ArraySize(reference_orders)-1;i>=0;i--)
      {
         if(reference_orders[i]!=order)
            continue;
         price=reference_prices[i];
         spread=reference_spreads[i];
         break;
      }

      if(order!=0 && order==market_reference_order)
      {
         price=last_market_reference;
         spread=last_trigger_spread;
         return;
      }

      if(!HistoryOrderSelect(order))
         return;

      ENUM_ORDER_TYPE type=
         (ENUM_ORDER_TYPE)HistoryOrderGetInteger(order,ORDER_TYPE);

      if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP)
      {
         double historical=HistoryOrderGetDouble(order,ORDER_PRICE_OPEN);
         if(historical>0.0)
         {
            if(price<=0.0 || MathAbs(price-historical)>p.tick_size*0.5)
               spread=-1.0;
            price=historical;
         }
      }
   }

   bool OurHistory(const ulong id)
   {
      if(id==0 || !HistorySelectByPosition(id))
         return false;

      bool own_entry=false;
      int n=HistoryDealsTotal();
      for(int i=0;i<n;i++)
      {
         ulong d=HistoryDealGetTicket(i);
         if(d==0 || HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol)
            continue;
         long type=HistoryDealGetInteger(d,DEAL_TYPE);
         if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL)
            continue;
         long e=HistoryDealGetInteger(d,DEAL_ENTRY);
         if(e!=DEAL_ENTRY_IN && e!=DEAL_ENTRY_INOUT)
            continue;
         if((ulong)HistoryDealGetInteger(d,DEAL_MAGIC)!=magic)
            return false;
         own_entry=true;
      }
      return own_entry;
   }

   void QueueDeal(const ulong deal,const double reference,
                  const double spread)
   {
      if(!WriteCsvJournal || deal==0)
         return;
      if(GlobalVariableCheck(Key("J_"+(string)deal)))
         return;
      int n=ArraySize(journal_deals);
      for(int i=0;i<n;i++)
         if(journal_deals[i]==deal)
            return;
      ArrayResize(journal_deals,n+1);
      ArrayResize(journal_refs,n+1);
      ArrayResize(journal_spreads,n+1);
      journal_deals[n]=deal;
      journal_refs[n]=reference;
      journal_spreads[n]=spread;
   }

   bool WriteJournal(const int index)
   {
      ulong deal=journal_deals[index];
      if(GlobalVariableCheck(Key("J_"+(string)deal)))
         return true;
      if(!HistoryDealSelect(deal))
         return false;

      ulong id=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      ulong order=(ulong)HistoryDealGetInteger(deal,DEAL_ORDER);
      long tm=HistoryDealGetInteger(deal,DEAL_TIME_MSC);
      ENUM_DEAL_TYPE type=
         (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal,DEAL_TYPE);
      ENUM_DEAL_ENTRY entry=
         (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
      ENUM_DEAL_REASON why=
         (ENUM_DEAL_REASON)HistoryDealGetInteger(deal,DEAL_REASON);
      double fill=HistoryDealGetDouble(deal,DEAL_PRICE);
      double volume=HistoryDealGetDouble(deal,DEAL_VOLUME);
      double profit=HistoryDealGetDouble(deal,DEAL_PROFIT);
      double commission=HistoryDealGetDouble(deal,DEAL_COMMISSION);
      double swap=HistoryDealGetDouble(deal,DEAL_SWAP);
      double fee=HistoryDealGetDouble(deal,DEAL_FEE);

      long first=tm;
      if(HistorySelectByPosition(id))
      {
         int n=HistoryDealsTotal();
         for(int i=0;i<n;i++)
         {
            ulong d=HistoryDealGetTicket(i);
            if(HistoryDealGetInteger(d,DEAL_ENTRY)!=DEAL_ENTRY_IN)
               continue;
            long t=HistoryDealGetInteger(d,DEAL_TIME_MSC);
            if(t<first)
               first=t;
         }
      }

      string ref="";
      string slip="";
      string spread="";
      if(journal_refs[index]>0.0 && p.point>0.0)
      {
         ref=DoubleToString(journal_refs[index],p.digits);
         double signed_slip=(type==DEAL_TYPE_BUY ?
            fill-journal_refs[index] : journal_refs[index]-fill)/p.point;
         slip=DoubleToString(signed_slip,3);
      }
      if(journal_spreads[index]>=0.0)
         spread=DoubleToString(journal_spreads[index],3);

      FolderCreate("Aurex");
      string name="Aurex\\"+instance_prefix+
         IntegerToString(AxDateKey((datetime)(tm/1000)))+".csv";

      int h=FileOpen(name,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
      if(h==INVALID_HANDLE)
         return false;
      if(FileSize(h)==0)
         FileWrite(h,"deal","order","position_id","time_msc","symbol",
                   "magic","entry","side","volume","reference","fill",
                   "slippage_points","spread_at_reference","profit",
                   "commission","swap","fee","duration_seconds","reason");
      FileSeek(h,0,SEEK_END);
      uint written=FileWrite(h,(string)deal,(string)order,(string)id,
         (string)tm,_Symbol,(string)magic,EnumToString(entry),
         EnumToString(type),DoubleToString(volume,8),ref,
         DoubleToString(fill,p.digits),slip,spread,
         DoubleToString(profit,8),DoubleToString(commission,8),
         DoubleToString(swap,8),DoubleToString(fee,8),
         DoubleToString((double)(tm-first)/1000.0,3),EnumToString(why));
      FileFlush(h);
      FileClose(h);
      if(written==0)
         return false;
      GlobalVariableSet(Key("J_"+(string)deal),(double)Now());
      return true;
   }

   void FlushJournal()
   {
      int processed=0;
      while(ArraySize(journal_deals)>0 && processed<8)
      {
         if(!WriteJournal(0))
            break;
         int n=ArraySize(journal_deals);
         for(int i=1;i<n;i++)
         {
            journal_deals[i-1]=journal_deals[i];
            journal_refs[i-1]=journal_refs[i];
            journal_spreads[i-1]=journal_spreads[i];
         }
         ArrayResize(journal_deals,n-1);
         ArrayResize(journal_refs,n-1);
         ArrayResize(journal_spreads,n-1);
         processed++;
      }
   }

   bool ContainsId(ulong &ids[],const ulong id)
   {
      for(int i=0;i<ArraySize(ids);i++)
         if(ids[i]==id)
            return true;
      return false;
   }

   void AddId(ulong &ids[],const ulong id)
   {
      if(id==0 || ContainsId(ids,id))
         return;
      int n=ArraySize(ids);
      ArrayResize(ids,n+1);
      ids[n]=id;
   }

   bool RecoverDay()
   {
      if(!HistorySelect(AxDayStart(Now()),Now()))
         return false;

      ulong deals[];
      int n=HistoryDealsTotal();
      ArrayResize(deals,n);
      for(int i=0;i<n;i++)
         deals[i]=HistoryDealGetTicket(i);

      ulong entries[];
      ulong exits[];
      ulong owned_deals[];
      for(int i=0;i<n;i++)
      {
         ulong d=deals[i];
         if(!HistoryDealSelect(d))
            return false;
         if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol)
            continue;
         long type=HistoryDealGetInteger(d,DEAL_TYPE);
         if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL)
            continue;
         ulong id=(ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID);
         ulong dm=(ulong)HistoryDealGetInteger(d,DEAL_MAGIC);
         long e=HistoryDealGetInteger(d,DEAL_ENTRY);
         if(dm==magic && (e==DEAL_ENTRY_IN || e==DEAL_ENTRY_INOUT))
            AddId(entries,id);
         if(e==DEAL_ENTRY_OUT || e==DEAL_ENTRY_OUT_BY ||
            e==DEAL_ENTRY_INOUT)
            AddId(exits,id);
         bool ours=(dm==magic);
         if(!ours)
            ours=OurHistory(id);
         if(ours)
            AddId(owned_deals,d);
      }

      long exit_times[];
      double exit_pnls[];
      double commission_sum=0.0;
      double volume_sum=0.0;

      for(int i=0;i<ArraySize(exits);i++)
      {
         ulong id=exits[i];
         if(PositionIdOpen(id) || !OurHistory(id))
            continue;
         double net=0.0,comm=0.0,vol=0.0;
         long final_time=0;
         int count=HistoryDealsTotal();
         for(int j=0;j<count;j++)
         {
            ulong d=HistoryDealGetTicket(j);
            long type=HistoryDealGetInteger(d,DEAL_TYPE);
            if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL)
               continue;
            long e=HistoryDealGetInteger(d,DEAL_ENTRY);
            double c=HistoryDealGetDouble(d,DEAL_COMMISSION);
            double f=HistoryDealGetDouble(d,DEAL_FEE);
            net+=HistoryDealGetDouble(d,DEAL_PROFIT)+c+f+
                 HistoryDealGetDouble(d,DEAL_SWAP);
            comm+=MathAbs(c)+MathAbs(f);
            if(e==DEAL_ENTRY_IN)
               vol+=HistoryDealGetDouble(d,DEAL_VOLUME);
            if(e==DEAL_ENTRY_OUT || e==DEAL_ENTRY_OUT_BY ||
               e==DEAL_ENTRY_INOUT)
            {
               long t=HistoryDealGetInteger(d,DEAL_TIME_MSC);
               if(t>final_time)
                  final_time=t;
            }
         }
         if(final_time<(long)AxDayStart(Now())*1000)
            continue;
         int s=ArraySize(exit_times);
         ArrayResize(exit_times,s+1);
         ArrayResize(exit_pnls,s+1);
         exit_times[s]=final_time;
         exit_pnls[s]=net;
         commission_sum+=comm;
         volume_sum+=vol;
      }

      for(int i=1;i<ArraySize(exit_times);i++)
      {
         long t=exit_times[i];
         double v=exit_pnls[i];
         int j=i-1;
         while(j>=0 && exit_times[j]>t)
         {
            exit_times[j+1]=exit_times[j];
            exit_pnls[j+1]=exit_pnls[j];
            j--;
         }
         exit_times[j+1]=t;
         exit_pnls[j+1]=v;
      }

      // Never reduce a persisted cap merely because history is incomplete.
      trades_today=(int)MathMax(trades_today,ArraySize(entries));
      consecutive_losses=0;
      for(int i=0;i<ArraySize(exit_pnls);i++)
         consecutive_losses=exit_pnls[i]<0.0 ? consecutive_losses+1 : 0;

      int closed=ArraySize(exit_times);
      if(closed>0)
      {
         int last=closed-1;
         int wait=exit_pnls[last]<0.0 ?
            CooldownAfterLossSecs : CooldownAfterWinSecs;
         cooldown_until=(datetime)(exit_times[last]/1000)+wait;
      }

      if(volume_sum>0.0)
      {
         observed_commission=commission_sum/volume_sum;
         commission_samples=closed;
      }

      for(int i=0;i<ArraySize(owned_deals);i++)
      {
         ulong d=owned_deals[i];
         if(!HistoryDealSelect(d))
            continue;
         ulong order=(ulong)HistoryDealGetInteger(d,DEAL_ORDER);
         double ref=0.0,spread=-1.0;
         DealReference(order,ref,spread);
         QueueDeal(d,ref,spread);
      }

      history_pending=false;
      last_history_refresh=GetTickCount64();
      Persist();
      return true;
   }

   void Backup()
   {
      if(!eligible || !own_lock)
         return;
      FolderCreate("Aurex");
      int h=FileOpen("Aurex\\"+instance_prefix+"state.csv",
                     FILE_WRITE|FILE_CSV|FILE_ANSI,',');
      if(h==INVALID_HANDLE)
         return;
      FileWrite(h,day_key,day_start_equity,(int)loss_trip,
                (int)profit_trip,trades_today,consecutive_losses,
                double_fills,extra_delta,(long)cooldown_until,
                slip_ewma,slip_samples,observed_commission,
                commission_samples,(string)last_counted_position);
      FileFlush(h);
      FileClose(h);
   }

   void RestoreFile()
   {
      if(GlobalVariableCheck(Key("DAY")))
         return;
      int h=FileOpen("Aurex\\"+instance_prefix+"state.csv",
                     FILE_READ|FILE_CSV|FILE_ANSI,',');
      if(h==INVALID_HANDLE)
         return;

      string v[14];
      bool valid=true;
      for(int i=0;i<14;i++)
      {
         if(FileIsEnding(h))
         {
            valid=false;
            break;
         }
         v[i]=FileReadString(h);
      }
      FileClose(h);
      if(!valid)
         return;

      int saved=(int)StringToInteger(v[0]);
      double equity=StringToDouble(v[1]);
      if(saved!=AxDateKey(Now()) || equity<=0.0)
         return;

      GlobalVariableSet(Key("DAY"),saved);
      GlobalVariableSet(Key("TRADES"),StringToInteger(v[4]));
      GlobalVariableSet(Key("LOSSES"),StringToInteger(v[5]));
      GlobalVariableSet(Key("RACES"),StringToInteger(v[6]));
      GlobalVariableSet(Key("EXTRA_DELTA"),StringToDouble(v[7]));
      GlobalVariableSet(Key("COOLDOWN"),StringToInteger(v[8]));
      GlobalVariableSet(Key("SLIP"),StringToDouble(v[9]));
      GlobalVariableSet(Key("SLIP_N"),StringToInteger(v[10]));
      GlobalVariableSet(Key("COMM"),StringToDouble(v[11]));
      GlobalVariableSet(Key("COMM_N"),StringToInteger(v[12]));
      SaveTicket("LAST_POS",(ulong)StringToInteger(v[13]));

      string suffix=IntegerToString(saved);
      string snapshot=account_prefix+"DAYSTART_"+suffix;
      if(!GlobalVariableCheck(snapshot))
         GlobalVariableSet(snapshot,equity);
      if(StringToInteger(v[2])!=0)
         GlobalVariableSet(account_prefix+"LOSS_"+suffix,1.0);
      if(StringToInteger(v[3])!=0)
         GlobalVariableSet(account_prefix+"PROFIT_"+suffix,1.0);
   }

   void Panel()
   {
      if(!ShowDashboard)
         return;
      ulong now=GetTickCount64();
      if(now-last_panel<250)
         return;
      last_panel=now;

      string label=object_prefix+"STATUS";
      string button=object_prefix+"KILL";
      if(ObjectFind(0,label)<0)
      {
         ObjectCreate(0,label,OBJ_LABEL,0,0,0);
         ObjectSetInteger(0,label,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(0,label,OBJPROP_XDISTANCE,12);
         ObjectSetInteger(0,label,OBJPROP_YDISTANCE,20);
         ObjectSetInteger(0,label,OBJPROP_COLOR,clrLightGray);
         ObjectSetInteger(0,label,OBJPROP_FONTSIZE,9);
         ObjectSetString(0,label,OBJPROP_FONT,"Consolas");
      }

      string text="AUREX BETA | "+_Symbol+" | "+AxStateName(state)+
         " | "+reason;
      ObjectSetString(0,label,OBJPROP_TEXT,text);

      // Individual labels avoid relying on multiline OBJ_LABEL rendering.
      string rows[6];
      rows[0]="Spread "+DoubleToString(md.spread,1)+"/"+
         IntegerToString(MaxSpreadPoints)+" | ATR "+
         DoubleToString(md.atr_points,1)+" ["+
         DoubleToString(MinAtrPoints,0)+","+
         DoubleToString(MaxAtrPoints,0)+"]";
      rows[1]="Lots "+DoubleToString(costs.lots,4)+" | cost/risk "+
         DoubleToString(costs.ratio*100.0,1)+"% | cost "+
         DoubleToString(costs.round_turn_points,1)+" pt / USD "+
         DoubleToString(costs.cash_cost,2);
      rows[2]="Day equity change "+
         DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY)-
                        day_start_equity,2)+" | loss limit "+
         DoubleToString(day_start_equity*DailyLossLimitPercent/100.0,2);
      rows[3]="Trades "+IntegerToString(trades_today)+" | losses "+
         IntegerToString(consecutive_losses)+" | double fills "+
         IntegerToString(double_fills);
      rows[4]="Slip "+DoubleToString(ExpectedSlip(),2)+" pt | commission "+
         DoubleToString(observed_commission,2)+"/"+
         DoubleToString(CommissionPerLotRoundTurn,2);
      rows[5]="Call latency p50/p95/p99 "+
         DoubleToString(LatencyPercentile(0.50),2)+"/"+
         DoubleToString(LatencyPercentile(0.95),2)+"/"+
         DoubleToString(LatencyPercentile(0.99),2)+
         " ms | tokens "+DoubleToString(limiter.Headroom(),1);

      for(int i=0;i<6;i++)
      {
         string name=object_prefix+"R"+IntegerToString(i);
         if(ObjectFind(0,name)<0)
         {
            ObjectCreate(0,name,OBJ_LABEL,0,0,0);
            ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
            ObjectSetInteger(0,name,OBJPROP_XDISTANCE,12);
            ObjectSetInteger(0,name,OBJPROP_YDISTANCE,42+i*19);
            ObjectSetInteger(0,name,OBJPROP_COLOR,clrLightGray);
            ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
            ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
         }
         ObjectSetString(0,name,OBJPROP_TEXT,rows[i]);
      }

      if(ObjectFind(0,button)<0)
      {
         ObjectCreate(0,button,OBJ_BUTTON,0,0,0);
         ObjectSetInteger(0,button,OBJPROP_XDISTANCE,12);
         ObjectSetInteger(0,button,OBJPROP_YDISTANCE,164);
         ObjectSetInteger(0,button,OBJPROP_XSIZE,220);
         ObjectSetInteger(0,button,OBJPROP_YSIZE,24);
         ObjectSetInteger(0,button,OBJPROP_BGCOLOR,clrMaroon);
         ObjectSetInteger(0,button,OBJPROP_COLOR,clrWhite);
      }
      ObjectSetString(0,button,OBJPROP_TEXT,
                      KillActive() ? "KILL ACTIVE - manual reset" :
                                     "HALT + FLATTEN ACCOUNT EAs");
   }

   void Step(const bool timer)
   {
      if(!initialized)
         return;
      if(!eligible)
      {
         Panel();
         return;
      }

      Heartbeat();
      if(!own_lock)
      {
         Panel();
         return;
      }

      bool online=(bool)TerminalInfoInteger(TERMINAL_CONNECTED);
      if(online!=connected)
      {
         connected=online;
         dirty=true;
         virtual_armed=false;
         cancel_all=true;
         SetState(online ? AX_RECONCILING : AX_PAUSED,
                  online ? "reconnected; reconciling" : "disconnected");
      }

      int previous_day=day_key;
      Daily();
      if(day_key!=previous_day)
         history_pending=true;
      Circuit();

      ulong now=GetTickCount64();
      if(timer && now-last_profile>=60000)
      {
         if(!p.Refresh(_Symbol))
         {
            hard_pause=true;
            cancel_all=true;
            SetState(AX_PAUSED,"symbol profile refresh failed");
         }
         last_profile=now;
      }
      p.RefreshDistances();
      bool quote_ok=md.Read(p,MaxSpreadPoints);
      if(timer && now-last_atr>=250)
      {
         md.RefreshAtr(p);
         last_atr=now;
      }

      if(!quote_ok || md.QuoteAgeMs()>MaxQuoteAgeMs)
      {
         virtual_armed=false;
         cancel_all=true;
      }

      bool flatten=false;
      string scheduled_reason="";
      if(!Schedule(scheduled_reason,flatten))
      {
         virtual_armed=false;
         cancel_all=true;
         if(flatten)
            force_flat=true;
      }

      if(busy && now-busy_since>=30000)
      {
         // A timeout is not evidence that a request did not execute.
         busy=false;
         hard_pause=true;
         cancel_all=true;
         quarantine_until=now+30000;
         SetState(AX_PAUSED,"request outcome unresolved; inspect and reattach");
      }

      if(timer && history_pending && now-last_history_refresh>=500)
      {
         last_history_refresh=now;
         RecoverDay();
      }

      if(dirty || now-last_reconcile>=
         (ulong)ReconcileIntervalSecs*1000)
         Reconcile();

      if(connected)
         Maintenance();

      if(timer)
      {
         FlushJournal();
         if(now-last_save_ms>=5000)
         {
            Persist();
            Backup();
            last_save_ms=now;
         }
      }

      AxLive live;
      Scan(live);
      if(live.positions>0)
      {
         if(md.QuoteAgeMs()>QuoteStallCloseMs &&
            now-last_stall_notice>=5000)
         {
            last_stall_notice=now;
            Log(0,"STALE_HOLD","server protection remains; no blind close");
         }
         Panel();
         return;
      }

      if(loss_trip || profit_trip || KillActive())
      {
         SetState(AX_HALTED,"daily halt or kill");
         Panel();
         return;
      }

      if(!quote_ok || md.QuoteAgeMs()>MaxQuoteAgeMs)
      {
         SetState(AX_PAUSED,"quote unavailable or stale");
         Panel();
         return;
      }

      if(busy || cancel_all || force_flat || history_pending ||
         now<quarantine_until)
      {
         SetState(AX_RECONCILING,"maintenance/history/request resolution");
         Panel();
         return;
      }

      string why="";
      if(!EntryGate(why))
      {
         virtual_armed=false;
         if(live.orders>0)
         {
            cancel_all=true;
            CancelPendings();
         }
         SetState(Now()<cooldown_until ? AX_COOLDOWN : AX_PAUSED,why);
         Panel();
         return;
      }

      if(live.orders>0)
      {
         if(ExecutionMode==SERVER_PENDING && live.orders==2 &&
            live.buy_order!=0 && live.sell_order!=0)
            Recentre();
         else
         {
            cancel_all=true;
            dirty=true;
         }
      }
      else if(virtual_armed)
         VirtualStep();
      else
      {
         Arm();
         if(ExecutionMode==SERVER_PENDING)
         {
            PutReference(cycle_buy,geometry.buy,md.spread);
            PutReference(cycle_sell,geometry.sell,md.spread);
         }
      }
      Panel();
   }

   ulong last_save_ms;

public:
   AxEngine()
   {
      state=AX_PAUSED;
      reason="not initialized";
      magic=0;
      eligible=false;
      is_gold=false;
      is_btc=false;
      connected=false;
      hedging=false;
      initialized=false;
      day_key=0;
      day_start_equity=0.0;
      loss_trip=false;
      profit_trip=false;
      trades_today=0;
      consecutive_losses=0;
      double_fills=0;
      extra_delta=0.0;
      slip_ewma=0.0;
      slip_samples=0;
      observed_commission=0.0;
      commission_samples=0;
      cooldown_until=0;
      last_reconcile=0;
      last_panel=0;
      last_atr=0;
      last_profile=0;
      last_heartbeat=0;
      last_buy_modify=0;
      last_sell_modify=0;
      last_trail=0;
      retry_after=0;
      quarantine_until=0;
      busy=false;
      busy_request=0;
      busy_since=0;
      busy_async=false;
      dirty=true;
      cancel_all=false;
      force_flat=false;
      virtual_armed=false;
      restoring=false;
      hard_pause=false;
      virtual_buy=0.0;
      virtual_sell=0.0;
      virtual_buy_hits=0;
      virtual_sell_hits=0;
      cycle_buy=0;
      cycle_sell=0;
      first_fill_order=0;
      last_market_reference=0.0;
      last_trigger_spread=-1.0;
      last_reference_time=0;
      ZeroMemory(costs);
      ZeroMemory(geometry);
      ArrayInitialize(latency,0.0);
      latency_count=0;
      latency_next=0;
      owner_stamp=0.0;
      own_lock=false;
      last_counted_position=0;
      close_candidate=0;
      close_candidate_since=0;
      market_ready=false;
      history_pending=true;
      last_history_refresh=0;
      last_stall_notice=0;
      market_reference_order=0;
      last_save_ms=0;
   }

   int Start()
   {
      if(!Validate() || !ExtraValidation())
         return INIT_PARAMETERS_INCORRECT;
      if(RunSelfTests && !BasicTests())
      {
         Print("AUREX event=SELFTEST_FAILED");
         return INIT_FAILED;
      }

      ResolveSymbol();
      string identity=AccountInfoString(ACCOUNT_SERVER)+"|"+
         (string)AccountInfoInteger(ACCOUNT_LOGIN)+"|"+
         (string)MQLInfoInteger(MQL_TESTER);
      account_prefix="A_"+StringFormat("%016I64X",HashText(identity))+"_";
      instance_prefix=account_prefix+
         StringFormat("%016I64X",HashText(_Symbol+"|"+(string)magic))+"_";
      object_prefix="AUREX_"+(string)ChartID()+"_";

      limiter.Init(MaxRequestsPerSecond,BurstRequests);
      hedging=(AccountInfoInteger(ACCOUNT_MARGIN_MODE)==
               ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
      connected=(bool)TerminalInfoInteger(TERMINAL_CONNECTED);

      if(!eligible)
      {
         initialized=true;
         history_pending=false;
         SetState(AX_PAUSED,"unsupported symbol; no trading");
         Panel();
         return INIT_SUCCEEDED;
      }

      if(!AcquireOwner())
      {
         SetState(AX_PAUSED,"duplicate instance for symbol and magic");
         Panel();
         return INIT_FAILED;
      }

      RestoreFile();
      slip_ewma=Load(Key("SLIP"),InitialSlippageEstimatePoints);
      slip_samples=(int)Load(Key("SLIP_N"),0.0);
      observed_commission=Load(Key("COMM"),0.0);
      commission_samples=(int)Load(Key("COMM_N"),0.0);

      if(!p.Refresh(_Symbol))
      {
         Print("AUREX event=PROFILE_FAILED symbol=",_Symbol);
         return INIT_FAILED;
      }
      if(!md.Init(_Symbol,AtrPeriod))
      {
         Print("AUREX event=ATR_INIT_FAILED symbol=",_Symbol);
         return INIT_FAILED;
      }
      market_ready=true;
      md.Read(p,MaxSpreadPoints);
      md.RefreshAtr(p);
      Daily();
      initialized=true;
      last_profile=GetTickCount64();
      cancel_all=true;
      virtual_armed=false;
      SetState(AX_RECONCILING,"startup reconciliation");
      RecoverDay();
      Reconcile();
      Panel();
      Log(1,"START","beta; no profitability or execution guarantee");
      return INIT_SUCCEEDED;
   }

   void Stop()
   {
      if(eligible && own_lock)
      {
         virtual_armed=false;
         if(CancelPendingsOnDeinit && initialized)
            CancelPendings();
         FlushJournal();
         Persist();
         Backup();

         AxLive live;
         Scan(live);
         if(CancelPendingsOnDeinit && live.orders>0)
            Log(0,"DEINIT_PENDING_REMAIN",
                "count="+IntegerToString(live.orders)+
                " cancellation not confirmed");

         GlobalVariableSetOnCondition(Key("OWNER"),0.0,owner_stamp);
         own_lock=false;
      }
      if(market_ready)
      {
         md.Release();
         market_ready=false;
      }
      if(object_prefix!="")
         ObjectsDeleteAll(0,object_prefix);
      initialized=false;
   }

   void QuoteEvent()
   {
      Step(false);
   }

   void TimerEvent()
   {
      Step(true);
   }

   void TradeEvent(const MqlTradeTransaction &trans,
                   const MqlTradeRequest &request,
                   const MqlTradeResult &result)
   {
      if(!initialized || !eligible || !own_lock)
         return;

      if(trans.type==TRADE_TRANSACTION_REQUEST)
      {
         if(request.symbol!=_Symbol || request.magic!=magic)
            return;

         Retcode(result.retcode,result.comment);
         if(busy && busy_async && result.request_id==busy_request)
            busy=false;

         if(Accepted(result.retcode) &&
            request.action==TRADE_ACTION_MODIFY)
            PutReference(request.order,request.price,-1.0);
         dirty=true;
         return;
      }

      if(trans.symbol!=_Symbol)
         return;
      dirty=true;
      if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0)
         return;

      if(!HistoryDealSelect(trans.deal))
      {
         history_pending=true;
         cancel_all=true;
         hard_pause=true;
         return;
      }

      ulong deal=trans.deal;
      ulong dm=(ulong)HistoryDealGetInteger(deal,DEAL_MAGIC);
      ulong id=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      ulong order=(ulong)HistoryDealGetInteger(deal,DEAL_ORDER);
      long e=HistoryDealGetInteger(deal,DEAL_ENTRY);
      long type=HistoryDealGetInteger(deal,DEAL_TYPE);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL)
         return;

      bool ours=(dm==magic);
      if(!ours)
         ours=OurHistory(id);
      if(!ours)
         return;

      bool entering=(e==DEAL_ENTRY_IN || e==DEAL_ENTRY_INOUT);
      bool exiting=(e==DEAL_ENTRY_OUT || e==DEAL_ENTRY_OUT_BY ||
                    e==DEAL_ENTRY_INOUT);

      double ref=0.0,spread=-1.0;
      DealReference(order,ref,spread);
      QueueDeal(deal,ref,spread);

      bool cycle_order=(order!=0 &&
                        (order==cycle_buy || order==cycle_sell));
      bool race=cycle_order && first_fill_order!=0 &&
                order!=first_fill_order;

      if(cycle_order && first_fill_order==0)
         first_fill_order=order;
      if(race)
      {
         // Clear cycle identifiers to count a partially-filled sibling once.
         cycle_buy=0;
         cycle_sell=0;
         double_fills++;
         if(double_fills>MaxDoubleFillsPerDay)
            extra_delta=MaxDistancePoints;
         Log(0,"RACE_DOUBLE_FILL",
             "count="+IntegerToString(double_fills)+
             " extra_delta="+DoubleToString(extra_delta,1));
      }

      if(entering && dm==magic)
      {
         virtual_armed=false;
         cancel_all=true;

         // History selection may have changed in ownership/reference lookup.
         if(HistoryDealSelect(deal))
            ObserveEntry(deal,ref,ref>0.0);

         SetState(AX_IN_POSITION,"entry deal confirmed");
         CancelPendings();
      }

      if(!busy_async)
         busy=false;

      if(exiting)
      {
         history_pending=true;
         close_candidate=id;
         close_candidate_since=GetTickCount64();
         cancel_all=true;
         virtual_armed=false;
      }

      // Recovery computes counters from complete position histories.
      history_pending=true;
      Persist();
      Backup();
      Reconcile();
      if(race)
         Maintenance();
   }

   void ChartEvent(const int id,const string &name)
   {
      if(!initialized || !eligible || !own_lock)
         return;
      if(id!=CHARTEVENT_OBJECT_CLICK || name!=object_prefix+"KILL")
         return;

      GlobalVariableSet(account_prefix+"KILL",1.0);
      GlobalVariablesFlush();
      ObjectSetInteger(0,name,OBJPROP_STATE,false);
      virtual_armed=false;
      cancel_all=true;
      force_flat=true;
      Circuit();
      Maintenance();
      Panel();
   }
};

// ==================== END OF FILE: Aurex_Engine_End.mqh ====================