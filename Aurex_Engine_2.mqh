// Part 2: book scan, arithmetic, sizing, gates and request handling.
// Continues AxEngine's private section.

   void Scan(AxBook &b)
   {
      ZeroMemory(b);

      for(int i=OrdersTotal()-1;i>=0;i--)
      {
         ulong ticket=OrderGetTicket(i);
         if(ticket==0 || OrderGetString(ORDER_SYMBOL)!=symbol)
            continue;

         if((ulong)OrderGetInteger(ORDER_MAGIC)!=magic)
         {
            if(!hedge)
               b.foreign=true;
            continue;
         }

         b.orders++;
         long type=OrderGetInteger(ORDER_TYPE);
         if(type==ORDER_TYPE_BUY_STOP)
            b.buy=ticket;
         if(type==ORDER_TYPE_SELL_STOP)
            b.sell=ticket;
      }

      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=symbol)
            continue;

         if((ulong)PositionGetInteger(POSITION_MAGIC)!=magic)
         {
            if(!hedge)
               b.foreign=true;
            continue;
         }

         b.positions++;
         b.position=ticket;
      }
   }

   bool PositionOpen(const ulong id)
   {
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(PositionGetTicket(i)==0)
            continue;
         if((ulong)PositionGetInteger(POSITION_IDENTIFIER)==id)
            return true;
      }
      return false;
   }

   bool HasId(ulong &items[],const ulong id)
   {
      for(int i=0;i<ArraySize(items);i++)
         if(items[i]==id)
            return true;
      return false;
   }

   void AddId(ulong &items[],const ulong id)
   {
      if(id==0 || HasId(items,id))
         return;
      int n=ArraySize(items);
      ArrayResize(items,n+1);
      items[n]=id;
   }

   double RiskCapital()
   {
      if(LotSizingMode==PCT_EQUITY)
         return AccountInfoDouble(ACCOUNT_EQUITY);
      if(LotSizingMode==PCT_FREE_MARGIN)
         return AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      return AccountInfoDouble(ACCOUNT_BALANCE);
   }

   double ProbeVolume()
   {
      double v=AxFloorLots(MathMin(1.0,volume_max),volume_step);
      return v>=volume_min ? v : volume_min;
   }

   bool LossPerLot(const ENUM_ORDER_TYPE side,
                   const double entry,const double exit,
                   double &loss)
   {
      double result=0.0;
      double probe=ProbeVolume();
      ResetLastError();

      if(!OrderCalcProfit(side,symbol,probe,entry,exit,result))
      {
         Log(0,"PROFIT_CALC_FAILED",
             "error="+IntegerToString(GetLastError())+
             " entry="+DoubleToString(entry,digits)+
             " exit="+DoubleToString(exit,digits));
         return false;
      }

      loss=MathAbs(result)/probe;
      return MathIsValidNumber(loss) && loss>0;
   }

   bool BuildPlan(string &why)
   {
      ZeroMemory(plan);
      Distances();

      double buy_tick=0.0,sell_tick=0.0;
      if(!LossPerLot(ORDER_TYPE_BUY,quote.ask,
                     quote.ask-tick_size,buy_tick) ||
         !LossPerLot(ORDER_TYPE_SELL,quote.bid,
                     quote.bid+tick_size,sell_tick))
      {
         why="OrderCalcProfit unavailable";
         return false;
      }

      double point_value=MathMax(buy_tick,sell_tick)*point/tick_size;
      if(point_value<=0)
      {
         why="point value unavailable";
         return false;
      }

      double slip=InitialSlippageEstimatePoints;
      double comm_points=CommissionPerLotRoundTurn/point_value;
      double cost_points=spread+comm_points+2.0*slip;

      double minimum=(double)stops+tick_size/point;
      plan.delta_points=MathMax(minimum,
         MathMax(DeltaPoints,atr_points*AtrDeltaFactor));

      plan.stop_points=MathMax(minimum,
         MathMax(StopPoints,atr_points*AtrStopFactor));

      // Size geometry and cost gate together. Do not defeat the gate by
      // dividing costs by an unused, oversized account risk budget.
      double cost_stop=cost_points/MaxCostToRiskRatio-
                       2.0*slip-comm_points;
      plan.stop_points=MathMax(plan.stop_points,
                               cost_stop+tick_size/point);

      double distance=plan.delta_points*point;
      double stop_distance=plan.stop_points*point;

      plan.buy=Up(quote.ask+distance);
      plan.sell=Down(quote.bid-distance);
      plan.buy_sl=Down(plan.buy-stop_distance);
      plan.sell_sl=Up(plan.sell+stop_distance);

      if(plan.sell<=0 || plan.buy_sl<=0)
      {
         why="nonpositive planned price";
         return false;
      }

      if(TpMultiplier>0)
      {
         double target=MathMax(minimum,
                               plan.stop_points*TpMultiplier)*point;
         plan.buy_tp=Up(plan.buy+target);
         plan.sell_tp=Down(plan.sell-target);

         if(plan.sell_tp<=0)
         {
            why="nonpositive sell TP";
            return false;
         }
         if(target/point-cost_points<MinNetTargetPoints)
         {
            why="TP below after-cost minimum";
            return false;
         }
      }
      else if(TslTriggerPoints-cost_points<MinNetTargetPoints)
      {
         why="trailing-only activation below after-cost minimum";
         return false;
      }

      double buy_loss=0.0,sell_loss=0.0;
      // Both entry and stop execution can slip adversely.
      if(!LossPerLot(ORDER_TYPE_BUY,
            plan.buy+slip*point,plan.buy_sl-slip*point,buy_loss) ||
         !LossPerLot(ORDER_TYPE_SELL,
            plan.sell-slip*point,plan.sell_sl+slip*point,sell_loss))
      {
         why="planned loss calculation failed";
         return false;
      }

      plan.unit_loss=MathMax(buy_loss,sell_loss)+
                     CommissionPerLotRoundTurn;
      plan.unit_cost=cost_points*point_value;
      plan.risk_budget=RiskCapital()*RiskPercent/100.0;

      if(plan.unit_loss<=0 || plan.risk_budget<=0)
      {
         why="risk capital unavailable";
         return false;
      }

      double ratio=plan.unit_cost/plan.unit_loss;
      if(ratio>MaxCostToRiskRatio+1e-8)
      {
         why="actual planned cost/risk="+DoubleToString(ratio,3);
         return false;
      }

      double lots=LotSizingMode==FIXED ? FixedLot :
                  plan.risk_budget/plan.unit_loss;
      lots=AxFloorLots(MathMin(lots,MathMin(MaxLot,volume_max)),
                       volume_step);

      if(lots<volume_min-1e-9)
      {
         why="minimum lot risk "+
             DoubleToString(plan.unit_loss*volume_min,2)+
             " exceeds budget/cap; budget="+
             DoubleToString(plan.risk_budget,2);
         return false;
      }

      // Margin is checked for both directions, not merely one leg.
      // Recalculate after each reduction; do not assume all margin is linear.
      double available=AccountInfoDouble(ACCOUNT_MARGIN_FREE)*
                       (1.0-MarginBufferPercent/100.0);

      for(int attempt=0;attempt<12;attempt++)
      {
         double bm=0.0,sm=0.0;
         if(!OrderCalcMargin(ORDER_TYPE_BUY,symbol,lots,plan.buy,bm) ||
            !OrderCalcMargin(ORDER_TYPE_SELL,symbol,lots,plan.sell,sm))
         {
            why="OrderCalcMargin unavailable";
            return false;
         }

         double required=bm+sm;
         if(required<=available+1e-8)
         {
            plan.lots=lots;
            return true;
         }

         double smaller=required>0 ?
            AxFloorLots(lots*MathMax(0.0,available)/required,
                         volume_step) : 0.0;

         if(smaller>=lots-volume_step*0.1)
            smaller=AxFloorLots(lots-volume_step,volume_step);
         lots=smaller;

         if(lots<volume_min-1e-9)
         {
            why="insufficient buffered margin for minimum-lot pair";
            return false;
         }
      }

      why="margin sizing did not converge";
      return false;
   }

   bool EntryGate(string &why)
   {
      if(!OwnerValid())
      {
         why="owner unavailable";
         return false;
      }
      if(hard_halt || uncertain)
      {
         why="execution fault; inspect Experts and reattach";
         return false;
      }
      if(Killed() || loss_trip || profit_trip || streak_trip)
      {
         why="kill/daily/streak circuit";
         return false;
      }
      if(history_dirty)
      {
         why="history reconciliation pending";
         return false;
      }
      if(day_equity<=0)
      {
         why="daily equity snapshot unavailable";
         return false;
      }
      if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      {
         why="terminal disconnected";
         return false;
      }
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED) ||
         !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
         !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
         !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      {
         why="algorithmic trading not permitted";
         return false;
      }

      bool flatten=false;
      if(!Schedule(why,flatten))
         return false;

      Distances();
      if(trade_mode!=SYMBOL_TRADE_MODE_FULL)
      {
         why="symbol does not allow both directions";
         return false;
      }
      if((order_flags & SYMBOL_ORDER_STOP)==0 ||
         (order_flags & SYMBOL_ORDER_SL)==0 ||
         (TpMultiplier>0 && (order_flags & SYMBOL_ORDER_TP)==0))
      {
         why="required pending/protective order type unsupported";
         return false;
      }
      if((expiration_flags & SYMBOL_EXPIRATION_GTC)==0)
      {
         why="GTC unsupported";
         return false;
      }
      if(QuoteAge()>MaxQuoteAgeMs)
      {
         why="stale quote";
         return false;
      }
      if(spread>MaxSpreadPoints || !spread_stable ||
         GetTickCount64()-stable_since<(ulong)SpreadStableMs)
      {
         why="spread high or stabilizing";
         return false;
      }
      if(!atr_valid)
      {
         why="closed M1 ATR warming up";
         return false;
      }
      if(atr_points<MinAtrPoints ||
         (MaxAtrPoints>0 && atr_points>MaxAtrPoints))
      {
         why="ATR outside configured bounds";
         return false;
      }
      if(MaxTradesPerDay>0 && trades_today>=MaxTradesPerDay)
      {
         why="daily entry cap";
         return false;
      }
      if(MaxConsecutiveLosses>0 && losses>=MaxConsecutiveLosses)
      {
         why="consecutive-loss cap";
         return false;
      }
      if(Now()<cooldown_until)
      {
         why="exit cooldown";
         return false;
      }

      AxBook b;
      Scan(b);
      if(b.foreign)
      {
         why="foreign order/position on exclusive netting symbol";
         return false;
      }
      return BuildPlan(why);
   }

   void Refill()
   {
      ulong now=GetTickCount64();
      double rate=MaxRequestsPerSecond;
      if(now<reduced_until)
         rate*=0.5;

      tokens=MathMin(BurstRequests,
                    tokens+(double)(now-refill_at)*rate/1000.0);
      refill_at=now;
   }

   bool Token(const bool maintenance)
   {
      Refill();
      if(GetTickCount64()<blocked_until)
         return false;

      double needed=maintenance ? 1.0 : 2.0;
      if(tokens+1e-9<needed)
         return false;

      tokens-=1.0;
      return true;
   }

   ENUM_ORDER_TYPE_FILLING MarketFilling()
   {
      if((fill_flags & SYMBOL_FILLING_FOK)!=0)
         return ORDER_FILLING_FOK;
      if((fill_flags & SYMBOL_FILLING_IOC)!=0)
         return ORDER_FILLING_IOC;

      if(execution==SYMBOL_TRADE_EXECUTION_MARKET)
         return ORDER_FILLING_FOK;
      return ORDER_FILLING_RETURN;
   }

   void Base(MqlTradeRequest &r,
             const ENUM_TRADE_REQUEST_ACTIONS action,
             const string comment)
   {
      ZeroMemory(r);
      r.action=action;
      r.symbol=symbol;
      r.magic=magic;
      r.deviation=(ulong)Slippage;
      r.type_time=ORDER_TIME_GTC;
      r.type_filling=(action==TRADE_ACTION_PENDING ||
                      action==TRADE_ACTION_MODIFY) ?
                     ORDER_FILLING_RETURN : MarketFilling();
      r.comment="AUREX130|"+comment;
   }

   bool Accepted(const uint code)
   {
      return code==TRADE_RETCODE_DONE ||
             code==TRADE_RETCODE_PLACED ||
             code==TRADE_RETCODE_DONE_PARTIAL;
   }

   void Failure(const uint code,const string detail,
                const bool submitted)
   {
      ulong now=GetTickCount64();
      Log(0,"REQUEST_FAILURE",
          "retcode="+IntegerToString((int)code)+" "+detail);

      if(code==TRADE_RETCODE_NO_CHANGES ||
         code==TRADE_RETCODE_ORDER_CHANGED ||
         code==TRADE_RETCODE_POSITION_CLOSED)
      {
         settle_until=now+(ulong)PairSettleMs;
         return;
      }

      if(code==TRADE_RETCODE_TOO_MANY_REQUESTS)
      {
         if(now>=reduced_until)
            backoff_ms=0;
         backoff_ms=backoff_ms==0 ? 250 :
                    (int)MathMin(8000,backoff_ms*2);
         blocked_until=now+(ulong)backoff_ms;
         reduced_until=now+60000;
         return;
      }

      if(code==TRADE_RETCODE_INVALID_STOPS ||
         code==TRADE_RETCODE_INVALID_PRICE ||
         code==TRADE_RETCODE_FROZEN ||
         code==TRADE_RETCODE_REQUOTE ||
         code==TRADE_RETCODE_PRICE_CHANGED ||
         code==TRADE_RETCODE_PRICE_OFF ||
         code==TRADE_RETCODE_LOCKED)
      {
         blocked_until=now+500;
         Distances();
         return;
      }

      if(code==TRADE_RETCODE_NO_MONEY ||
         code==TRADE_RETCODE_MARKET_CLOSED ||
         code==TRADE_RETCODE_TRADE_DISABLED ||
         code==TRADE_RETCODE_CLIENT_DISABLES_AT ||
         code==TRADE_RETCODE_SERVER_DISABLES_AT)
      {
         blocked_until=now+5000;
         cancel_requested=true;
         return;
      }

      if(submitted &&
         (code==TRADE_RETCODE_TIMEOUT ||
          code==TRADE_RETCODE_CONNECTION || code==0))
      {
         uncertain=true;
         hard_halt=true;
         cancel_requested=true;
         Log(0,"AMBIGUOUS_EXECUTION",
             "entries and further DEAL requests blocked; inspect "
             "broker state before reattaching");
         return;
      }

      hard_halt=true;
      cancel_requested=true;
      State("HALTED","unhandled execution/preflight failure; inspect log");
   }

   bool Preflight(MqlTradeRequest &r)
   {
      MqlTradeCheckResult c;
      ZeroMemory(c);
      ResetLastError();

      if(OrderCheck(r,c))
         return true;

      Failure(c.retcode,
         "stage=check action="+EnumToString(r.action)+
         " volume="+DoubleToString(r.volume,8)+
         " price="+DoubleToString(r.price,digits)+
         " sl="+DoubleToString(r.sl,digits)+
         " tp="+DoubleToString(r.tp,digits)+
         " error="+IntegerToString(GetLastError())+
         " comment="+c.comment,false);
      return false;
   }

   bool Send(MqlTradeRequest &r,const bool maintenance,
             MqlTradeResult &result)
   {
      ZeroMemory(result);
      if(!OwnerValid())
         return false;
      if(!TerminalInfoInteger(TERMINAL_CONNECTED))
         return false;
      if(uncertain && r.action==TRADE_ACTION_DEAL)
         return false;
      if(GetTickCount64()<blocked_until)
         return false;
      if(!Token(maintenance))
         return false;

      // Check every request, including cancellation and protective changes.
      if(!Preflight(r))
         return false;

      ResetLastError();
      ulong begin=GetMicrosecondCount();
      bool ok=OrderSend(r,result);
      ulong spent=GetMicrosecondCount()-begin;

      if(!ok || !Accepted(result.retcode))
      {
         Failure(result.retcode,
            "stage=send action="+EnumToString(r.action)+
            " error="+IntegerToString(GetLastError())+
            " comment="+result.comment,true);
         return false;
      }

      settle_until=GetTickCount64()+(ulong)PairSettleMs;
      return true;
   }
