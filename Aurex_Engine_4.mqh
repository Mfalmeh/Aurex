// Part 4: lifecycle, orchestration, transaction handling and dashboard.
// Closes AxEngine.

   void Panel()
   {
      if(!ShowDashboard)
         return;
      ulong now=GetTickCount64();
      if(now-last_panel<250)
         return;
      last_panel=now;

      string rows[6];
      rows[0]="AUREX 1.10 | "+symbol+" | "+state;
      rows[1]=state_reason;
      rows[2]="Spread "+DoubleToString(spread,1)+"/"+
         IntegerToString(MaxSpreadPoints)+" pt | ATR "+
         DoubleToString(atr_points,1)+" pt";
      rows[3]="Lots "+DoubleToString(plan.lots,4)+
         " | planned loss "+DoubleToString(plan.lots*plan.unit_loss,2)+
         " | cost "+DoubleToString(plan.lots*plan.unit_cost,2);
      rows[4]="Trades "+IntegerToString(trades_today)+"/"+
         IntegerToString(MaxTradesPerDay)+" | losses "+
         IntegerToString(losses)+" | equity change "+
         DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY)-day_equity,2);
      rows[5]="Stop "+DoubleToString(plan.stop_points,1)+
         " pt | delta "+DoubleToString(plan.delta_points,1)+
         " pt | account "+AccountInfoString(ACCOUNT_CURRENCY);

      for(int i=0;i<6;i++)
      {
         string name=objects+"R"+IntegerToString(i);
         if(ObjectFind(0,name)<0)
         {
            ObjectCreate(0,name,OBJ_LABEL,0,0,0);
            ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
            ObjectSetInteger(0,name,OBJPROP_XDISTANCE,12);
            ObjectSetInteger(0,name,OBJPROP_YDISTANCE,20+i*20);
            ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
            ObjectSetInteger(0,name,OBJPROP_COLOR,clrLightGray);
            ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
         }
         ObjectSetString(0,name,OBJPROP_TEXT,rows[i]);
      }

      string button=objects+"KILL";
      if(ObjectFind(0,button)<0)
      {
         ObjectCreate(0,button,OBJ_BUTTON,0,0,0);
         ObjectSetInteger(0,button,OBJPROP_XDISTANCE,12);
         ObjectSetInteger(0,button,OBJPROP_YDISTANCE,150);
         ObjectSetInteger(0,button,OBJPROP_XSIZE,310);
         ObjectSetInteger(0,button,OBJPROP_YSIZE,25);
         ObjectSetInteger(0,button,OBJPROP_BGCOLOR,clrMaroon);
         ObjectSetInteger(0,button,OBJPROP_COLOR,clrWhite);
      }

      ObjectSetString(0,button,OBJPROP_TEXT,
         Killed() ? "KILL ACTIVE - CLICK TO RESET WHEN FLAT" :
                    "HALT + FLATTEN AUREX INSTANCES");
   }

   bool SafeToResetKill()
   {
      // Check both configured magic numbers throughout this terminal's
      // current account. Do not clear a shared kill while a sibling
      // instance still has managed exposure.
      for(int i=OrdersTotal()-1;i>=0;i--)
      {
         if(OrderGetTicket(i)==0)
            continue;
         ulong m=(ulong)OrderGetInteger(ORDER_MAGIC);
         if(m==MagicNumberGold || m==MagicNumberBtc)
            return false;
      }

      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(PositionGetTicket(i)==0)
            continue;
         ulong m=(ulong)PositionGetInteger(POSITION_MAGIC);
         if(m==MagicNumberGold || m==MagicNumberBtc)
            return false;
      }
      return true;
   }

public:
   AxEngine()
   {
      symbol="";
      ap="";
      ip="";
      objects="";
      state="PAUSED";
      state_reason="not initialized";
      magic=0;
      gold=false;
      btc=false;
      hedge=false;
      initialized=false;
      owns=false;
      hard_halt=false;
      uncertain=false;
      cancel_requested=false;
      flatten_requested=false;
      loss_trip=false;
      profit_trip=false;
      streak_trip=false;
      history_dirty=true;
      session_warning=false;
      quote_valid=false;
      atr_valid=false;
      owner_value=0;
      point=0;
      tick_size=0;
      volume_min=0;
      volume_max=0;
      volume_step=0;
      digits=0;
      stops=0;
      freeze=0;
      fill_flags=0;
      execution=0;
      trade_mode=0;
      order_flags=0;
      expiration_flags=0;
      atr_handle=INVALID_HANDLE;
      atr_points=0;
      ZeroMemory(quote);
      last_quote_msc=0;
      last_quote_local=0;
      stable_since=0;
      spread_stable=false;
      spread=0;
      day_key=0;
      day_equity=0;
      trades_today=0;
      losses=0;
      cooldown_until=0;
      last_exit_time=0;
      tokens=0;
      refill_at=0;
      blocked_until=0;
      reduced_until=0;
      backoff_ms=0;
      settle_until=0;
      last_profile=0;
      last_atr=0;
      last_history=0;
      last_heartbeat=0;
      last_panel=0;
      last_save=0;
      last_trail=0;
      last_modify=0;
      modify_buy_next=true;
      cycle_buy=0;
      cycle_sell=0;
      first_fill=0;
      ZeroMemory(plan);
   }

   int Start()
   {
      symbol=_Symbol;
      if(!Validate())
         return INIT_PARAMETERS_INCORRECT;

      if(!Resolve())
      {
         Log(0,"UNSUPPORTED_SYMBOL",
             "set exact GoldSymbol or BtcSymbol for this chart");
         return INIT_PARAMETERS_INCORRECT;
      }

      string identity=AccountInfoString(ACCOUNT_SERVER)+"|"+
         (string)AccountInfoInteger(ACCOUNT_LOGIN)+"|"+
         (string)MQLInfoInteger(MQL_TESTER);
      ap="AX2_"+StringFormat("%016I64X",AxHash(identity))+"_";
      ip=ap+StringFormat("%016I64X",
         AxHash(symbol+"|"+(string)magic))+"_";
      objects="AUREX110_"+(string)ChartID()+"_";

      if(!Acquire())
      {
         Log(0,"OWNER_BUSY",
             "another chart owns symbol/magic, or its lease has not expired");
         return INIT_FAILED;
      }

      if(!Profile())
      {
         Log(0,"PROFILE_FAILED",
             "point="+DoubleToString(point,8)+
             " tick="+DoubleToString(tick_size,8)+
             " min="+DoubleToString(volume_min,8)+
             " step="+DoubleToString(volume_step,8));
         return INIT_FAILED;
      }

      atr_handle=iATR(symbol,PERIOD_M1,AtrPeriod);
      if(atr_handle==INVALID_HANDLE)
      {
         Log(0,"ATR_INIT_FAILED",
             "error="+IntegerToString(GetLastError()));
         return INIT_FAILED;
      }

      hedge=AccountInfoInteger(ACCOUNT_MARGIN_MODE)==
            ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
      tokens=BurstRequests;
      refill_at=GetTickCount64();
      last_profile=refill_at;

      ReadQuote();
      ReadAtr();
      Daily();
      Recover();

      initialized=true;
      cancel_requested=true;
      settle_until=GetTickCount64()+(ulong)PairSettleMs;

      // Cancel inherited pending orders first. Keep a single protected
      // managed position; flatten duplicate positions.
      AxBook b;
      Scan(b);
      if(b.positions>1)
         flatten_requested=true;

      Log(1,"PROFILE",
          "digits="+IntegerToString(digits)+
          " point="+DoubleToString(point,8)+
          " tick_size="+DoubleToString(tick_size,8)+
          " volume_min="+DoubleToString(volume_min,8)+
          " volume_step="+DoubleToString(volume_step,8)+
          " stops="+IntegerToString(stops)+
          " freeze="+IntegerToString(freeze)+
          " account_currency="+AccountInfoString(ACCOUNT_CURRENCY)+
          " hedging="+(hedge ? "true" : "false"));

      if(!hedge)
         Log(0,"NETTING_EXCLUSIVITY",
             "do not trade this symbol manually or with another EA");

      State("RECONCILING","startup; cancel inherited pending orders");
      Panel();
      return INIT_SUCCEEDED;
   }

   void Stop()
   {
      if(owns && OwnerValid())
      {
         if(initialized && CancelPendingsOnDeinit)
         {
            // Bounded attempts. Never imply that deinit guarantees cancel.
            for(int i=0;i<8;i++)
            {
               AxBook b;
               Scan(b);
               if(b.orders==0)
                  break;
               if(!CancelOne())
                  break;
            }

            AxBook remaining;
            Scan(remaining);
            if(remaining.orders>0)
               Log(0,"DEINIT_PENDING_REMAIN",
                   "count="+IntegerToString(remaining.orders)+
                   " inspect broker orders");
         }

         Persist();
         for(int i=0;i<8 && ArraySize(journal_queue)>0;i++)
            FlushJournal();
         GlobalVariablesFlush();
         GlobalVariableSetOnCondition(Key("OWNER2"),0.0,owner_value);
         owns=false;
      }

      if(atr_handle!=INVALID_HANDLE)
      {
         IndicatorRelease(atr_handle);
         atr_handle=INVALID_HANDLE;
      }
      if(objects!="")
         ObjectsDeleteAll(0,objects);
      initialized=false;
   }

   void Step(const bool timer)
   {
      if(!initialized)
         return;

      Heartbeat();
      if(!OwnerValid())
      {
         Panel();
         return;
      }

      ulong now=GetTickCount64();
      Daily();
      Circuit();

      if(timer && now-last_profile>=60000)
      {
         if(!Profile())
         {
            hard_halt=true;
            cancel_requested=true;
            State("HALTED","symbol profile refresh failed");
         }
         last_profile=now;
      }

      ReadQuote();
      if(timer && now-last_atr>=500)
      {
         ReadAtr();
         last_atr=now;
      }

      bool schedule_flat=false;
      string schedule_reason="";
      bool schedule_ok=Schedule(schedule_reason,schedule_flat);
      if(!schedule_ok)
      {
         cancel_requested=true;
         if(schedule_flat)
            flatten_requested=true;
      }

      if(QuoteAge()>MaxQuoteAgeMs ||
         !TerminalInfoInteger(TERMINAL_CONNECTED))
      {
         cancel_requested=true;
         spread_stable=false;
      }

      if(timer && history_dirty && now>=settle_until &&
         now-last_history>=1000)
      {
         last_history=now;
         Recover();
         Circuit();
      }

      if(timer)
      {
         FlushJournal();
         if(now-last_save>=5000)
         {
            Persist();
            GlobalVariablesFlush();
            last_save=now;
         }
      }

      AxBook b;
      Scan(b);

      if(b.foreign && !hedge)
      {
         cancel_requested=true;
         hard_halt=true;
         State("HALTED","foreign netting exposure; ownership not assumed");
      }

      if(b.positions>1)
      {
         // No intentional hedge retention: flatten ALL managed positions.
         cancel_requested=true;
         flatten_requested=true;
         State("RECONCILING","multiple fills; flattening managed exposure");
      }

      if(b.positions>0)
         cancel_requested=true;

      // Cancellation is allowed during a settle window: it reduces exposure.
      if(cancel_requested && b.orders>0)
      {
         CancelOne();
         Scan(b);
      }

      if(cancel_requested && b.orders==0 && now>=settle_until)
         cancel_requested=false;

      if(flatten_requested && b.positions==0 &&
         b.orders==0 && now>=settle_until)
         flatten_requested=false;

      if(b.positions>0)
      {
         if(!b.foreign && now>=settle_until)
         {
            if(flatten_requested)
               CloseOne();
            else
               Protect(b.position);
         }

         if(uncertain)
            State("HALTED","ambiguous request; inspect broker position");
         else if(flatten_requested)
            State("RECONCILING","forced flatten pending");
         else if(!b.foreign)
            State("IN_POSITION","managed position; server protection active");

         Panel();
         return;
      }

      if(Killed() || loss_trip || profit_trip || streak_trip ||
         hard_halt || uncertain)
      {
         State("HALTED",
            Killed() ? "manual account-scoped kill" :
            loss_trip ? "daily loss circuit" :
            profit_trip ? "daily profit lock" :
            streak_trip ? "daily consecutive-loss circuit" :
                          "execution fault; inspect Experts and reattach");
         Panel();
         return;
      }

      if(cancel_requested || flatten_requested || now<settle_until)
      {
         State("RECONCILING","settlement or managed-order cleanup");
         Panel();
         return;
      }

      // A single remaining pending order is not a valid straddle.
      // Only diagnose it after the placement settlement interval.
      if(b.orders>0 &&
         (b.orders!=2 || b.buy==0 || b.sell==0))
      {
         cancel_requested=true;
         State("RECONCILING","settled orphan/unexpected pending set");
         CancelOne();
         Panel();
         return;
      }

      string why="";
      if(!EntryGate(why))
      {
         if(b.orders>0)
         {
            cancel_requested=true;
            CancelOne();
         }
         State(Now()<cooldown_until ? "COOLDOWN" : "PAUSED",why);
         Panel();
         return;
      }

      if(b.orders==2)
      {
         cycle_buy=b.buy;
         cycle_sell=b.sell;
         State("ARMED","buy-stop and sell-stop confirmed in broker book");
         Recentre(b);
      }
      else
      {
         State("IDLE","flat; entry gates passed");
         Arm();
      }

      Panel();
   }

   void TradeEvent(const MqlTradeTransaction &trans,
                   const MqlTradeRequest &request,
                   const MqlTradeResult &result)
   {
      if(!initialized || !OwnerValid())
         return;

      if(trans.type==TRADE_TRANSACTION_REQUEST)
      {
         // Synchronous Send already processes its immediate result.
         // Transaction events are not used to submit another order here.
         return;
      }

      if(trans.symbol!=symbol)
         return;

      if(trans.type==TRADE_TRANSACTION_ORDER_ADD ||
         trans.type==TRADE_TRANSACTION_ORDER_UPDATE ||
         trans.type==TRADE_TRANSACTION_ORDER_DELETE)
      {
         // Let local order/position caches settle before a new entry.
         settle_until=GetTickCount64()+(ulong)PairSettleMs;
      }

      if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0)
         return;

      if(!HistoryDealSelect(trans.deal))
      {
         history_dirty=true;
         hard_halt=true;
         cancel_requested=true;
         Log(0,"DEAL_HISTORY_UNAVAILABLE",
             "deal="+(string)trans.deal+" inspect and reattach");
         return;
      }

      ulong d=trans.deal;
      long type=HistoryDealGetInteger(d,DEAL_TYPE);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL)
         return;

      ulong dm=(ulong)HistoryDealGetInteger(d,DEAL_MAGIC);
      ulong id=(ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID);
      ulong order=(ulong)HistoryDealGetInteger(d,DEAL_ORDER);
      long entry=HistoryDealGetInteger(d,DEAL_ENTRY);

      bool entering=(entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_INOUT);
      bool exiting=(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY ||
                    entry==DEAL_ENTRY_INOUT);
      bool cycle=(order!=0 && (order==cycle_buy || order==cycle_sell));

      // Any symbol deal can affect an exclusive netting position.
      history_dirty=true;
      settle_until=GetTickCount64()+(ulong)PairSettleMs;

      if(dm!=magic)
      {
         if(!hedge && entering)
         {
            AxBook b;
            Scan(b);
            if(b.positions>0 || b.orders>0)
            {
               hard_halt=true;
               cancel_requested=true;
               Log(0,"FOREIGN_NETTING_DEAL",
                   "another trader entered managed symbol");
            }
         }
         return;
      }

      QueueJournal(d);
      Log(1,"DEAL",
          "deal="+(string)d+" order="+(string)order+
          " position="+(string)id+
          " entry="+EnumToString((ENUM_DEAL_ENTRY)entry)+
          " volume="+DoubleToString(
             HistoryDealGetDouble(d,DEAL_VOLUME),8)+
          " price="+DoubleToString(
             HistoryDealGetDouble(d,DEAL_PRICE),digits));

      if(cycle)
      {
         if(first_fill==0)
            first_fill=order;
         else if(order!=first_fill)
         {
            cancel_requested=true;
            flatten_requested=true;
            Log(0,"DOUBLE_FILL",
                "both pending legs executed; cancel and flatten");
            // Keep cycle IDs until the next completely new pair.
         }
      }

      if(entering)
      {
         if(!HasId(seen_positions,id))
         {
            AddId(seen_positions,id);
            trades_today++;
         }
         cancel_requested=true;
      }

      if(exiting)
         cancel_requested=true;

      if(entry==DEAL_ENTRY_INOUT)
      {
         // A netting reversal is not an intended second entry.
         flatten_requested=true;
         cancel_requested=true;
         Log(0,"NETTING_REVERSAL","flatten requested");
      }

      Persist();

      // Immediate sibling cancellation, still subject to token/backoff
      // and the broker's freeze/market rules.
      if(cancel_requested)
         CancelOne();
   }

   void ChartEvent(const int id,const string name)
   {
      if(!initialized || !OwnerValid() ||
         id!=CHARTEVENT_OBJECT_CLICK || name!=objects+"KILL")
         return;

      ObjectSetInteger(0,name,OBJPROP_STATE,false);

      if(Killed())
      {
         if(uncertain || !SafeToResetKill())
         {
            Log(0,"KILL_RESET_REFUSED",
                "managed exposure or ambiguous execution remains");
            return;
         }

         GlobalVariableSet(ap+"KILL2",0.0);
         Log(0,"KILL_RESET",
             "manual kill cleared; other circuits remain enforced");
      }
      else
      {
         GlobalVariableSet(ap+"KILL2",1.0);
         cancel_requested=true;
         flatten_requested=true;
         Log(0,"MANUAL_KILL",
             "halt and flatten requested for participating Aurex instances");
         CancelOne();
      }

      GlobalVariablesFlush();
      Circuit();
      last_panel=0;
      Panel();
   }
};
