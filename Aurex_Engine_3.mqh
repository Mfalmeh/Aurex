// Part 3: placement, cancellation, protective management and history.
// Continues AxEngine's private section.

   bool CancelOne()
   {
      for(int i=OrdersTotal()-1;i>=0;i--)
      {
         ulong ticket=OrderGetTicket(i);
         if(ticket==0 || OrderGetString(ORDER_SYMBOL)!=symbol ||
            (ulong)OrderGetInteger(ORDER_MAGIC)!=magic)
            continue;

         MqlTradeRequest r;
         MqlTradeResult result;
         Base(r,TRADE_ACTION_REMOVE,"CANCEL");
         r.order=ticket;

         // Do not invent a freeze zone when broker freeze level is zero.
         // The broker check is authoritative; cancellation is attempted.
         return Send(r,true,result);
      }
      return false;
   }

   bool CloseOne()
   {
      if(uncertain || !ReadQuote() || QuoteAge()>MaxQuoteAgeMs)
         return false;

      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=symbol ||
            (ulong)PositionGetInteger(POSITION_MAGIC)!=magic)
            continue;

         ENUM_POSITION_TYPE type=
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         MqlTradeRequest r;
         MqlTradeResult result;
         Base(r,TRADE_ACTION_DEAL,"CLOSE");
         r.position=ticket;
         r.volume=PositionGetDouble(POSITION_VOLUME);
         r.type=type==POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         r.price=type==POSITION_TYPE_BUY ? quote.bid : quote.ask;

         bool ok=Send(r,true,result);
         if(ok)
            history_dirty=true;
         return ok;
      }
      return false;
   }

   void Arm()
   {
      AxBook b;
      Scan(b);
      if(b.orders!=0 || b.positions!=0 || b.foreign ||
         cancel_requested || flatten_requested || uncertain)
         return;

      Refill();
      if(tokens<3.0 || GetTickCount64()<blocked_until)
         return;

      MqlTradeRequest buy,sell;
      MqlTradeResult br,sr;
      Base(buy,TRADE_ACTION_PENDING,"BUY");
      Base(sell,TRADE_ACTION_PENDING,"SELL");

      buy.type=ORDER_TYPE_BUY_STOP;
      buy.volume=plan.lots;
      buy.price=plan.buy;
      buy.sl=plan.buy_sl;
      buy.tp=plan.buy_tp;

      sell.type=ORDER_TYPE_SELL_STOP;
      sell.volume=plan.lots;
      sell.price=plan.sell;
      sell.sl=plan.sell_sl;
      sell.tp=plan.sell_tp;

      if(!Preflight(buy) || !Preflight(sell))
         return;

      cycle_buy=0;
      cycle_sell=0;
      first_fill=0;

      Log(1,"ARM_PLAN",
          "lots="+DoubleToString(plan.lots,8)+
          " buy="+DoubleToString(plan.buy,digits)+
          " sell="+DoubleToString(plan.sell,digits)+
          " stop_pt="+DoubleToString(plan.stop_points,1)+
          " delta_pt="+DoubleToString(plan.delta_points,1)+
          " estimated_loss="+DoubleToString(plan.unit_loss*plan.lots,2)+
          " estimated_cost="+DoubleToString(plan.unit_cost*plan.lots,2));

      if(!Send(buy,false,br))
      {
         if(uncertain)
            cancel_requested=true;
         return;
      }

      cycle_buy=br.order;

      // First-leg activation can precede the return of OrderSend.
      Scan(b);
      if(cycle_buy==0 || !OrderSelect(cycle_buy) ||
         b.positions!=0 || b.foreign)
      {
         cancel_requested=true;
         State("RECONCILING","first leg changed before second placement");
         return;
      }

      // Obtain fresh prices before the second placement. Never chase a
      // moved quote with a stale, now-invalid pending entry.
      if(!ReadQuote() || QuoteAge()>MaxQuoteAgeMs ||
         spread>MaxSpreadPoints)
      {
         cancel_requested=true;
         State("RECONCILING","quote changed during pair placement");
         return;
      }

      Distances();
      double minimum=((double)stops+tick_size/point)*point;
      if(sell.price>quote.bid-minimum+tick_size*0.1)
      {
         cancel_requested=true;
         State("RECONCILING","sell entry became too close during placement");
         return;
      }

      Circuit();
      if(Killed() || loss_trip || profit_trip || streak_trip)
      {
         cancel_requested=true;
         return;
      }

      if(!Send(sell,false,sr))
      {
         cancel_requested=true;
         State("RECONCILING","second leg rejected; cancel first");
         return;
      }

      cycle_sell=sr.order;
      if(cycle_sell==0)
         cancel_requested=true;

      settle_until=GetTickCount64()+(ulong)PairSettleMs;
      State("RECONCILING","pair accepted; awaiting settled broker book");
   }

   void Recentre(const AxBook &b)
   {
      ulong now=GetTickCount64();
      if(now-last_modify<(ulong)RecentreMinMs)
         return;

      for(int pass=0;pass<2;pass++)
      {
         bool buy_side=pass==0 ? modify_buy_next : !modify_buy_next;
         ulong ticket=buy_side ? b.buy : b.sell;
         if(ticket==0 || !OrderSelect(ticket))
            continue;

         double old=OrderGetDouble(ORDER_PRICE_OPEN);
         double distance=buy_side ?
            (old-quote.ask)/point : (quote.bid-old)/point;

         // Leave an approached trigger alone: price is coming to it.
         if(distance<=plan.delta_points+MaxDistancePoints)
            continue;

         // Require a real excursion before the anchor moves. Without this
         // guard every quote change re-established the gap between the pair
         // and the market, so the trigger could never be reached between
         // modification passes and nothing ever filled.
         if(distance<plan.delta_points*RecentreDriftFactor)
            continue;

         Distances();
         if(freeze>0 && distance<=(double)freeze+tick_size/point)
            continue;

         double volume=OrderGetDouble(ORDER_VOLUME_CURRENT);
         double target=buy_side ? plan.buy : plan.sell;
         double sl=buy_side ? plan.buy_sl : plan.sell_sl;
         double tp=buy_side ? plan.buy_tp : plan.sell_tp;

         double actual=0.0;
         double slip=InitialSlippageEstimatePoints*point;
         if(!LossPerLot(buy_side ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
              target+(buy_side ? slip : -slip),
              sl+(buy_side ? -slip : slip),actual))
            return;
         actual=(actual+CommissionPerLotRoundTurn)*volume;

         // Pending volume cannot be changed by MODIFY.
         // Cancel/rebuild if its new geometry would exceed the risk budget.
         if(LotSizingMode!=FIXED &&
            actual>plan.risk_budget+0.01)
         {
            cancel_requested=true;
            State("RECONCILING","pending volume no longer fits current risk");
            return;
         }

         MqlTradeRequest r;
         MqlTradeResult result;
         Base(r,TRADE_ACTION_MODIFY,buy_side ? "MOVE_BUY" : "MOVE_SELL");
         r.order=ticket;
         r.price=target;
         r.sl=sl;
         r.tp=tp;

         if(MathAbs(target-old)<tick_size*0.5)
            continue;

         if(Send(r,false,result))
         {
            last_modify=now;
            modify_buy_next=!buy_side;
         }
         return;
      }
   }

   void Protect(const ulong ticket)
   {
      ulong now=GetTickCount64();
      if(now-last_trail<(ulong)TslMinIntervalMs ||
         !PositionSelectByTicket(ticket) ||
         QuoteAge()>MaxQuoteAgeMs)
         return;

      bool buy=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double old_sl=PositionGetDouble(POSITION_SL);
      double old_tp=PositionGetDouble(POSITION_TP);
      double market=buy ? quote.bid : quote.ask;
      double profit=(buy ? market-entry : entry-market)/point;

      Distances();
      double minimum=((double)MathMax(stops,freeze)+tick_size/point)*point;
      double candidate=old_sl;
      double tp=old_tp;

      if(old_sl<=0)
      {
         // Unexpected loss of protection is not repaired with an
         // arbitrarily wider stop. Request flattening instead.
         flatten_requested=true;
         cancel_requested=true;
         Log(0,"MISSING_SL","position="+(string)ticket+
             " forced closure requested");
         return;
      }

      if(BreakEvenAtPoints>0 && profit>=BreakEvenAtPoints)
      {
         double one_tick=0.0;
         if(LossPerLot(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
              entry,entry+(buy ? -tick_size : tick_size),one_tick))
         {
            double pv=one_tick*point/tick_size;
            double offset=(CommissionPerLotRoundTurn/pv+
                           2.0*InitialSlippageEstimatePoints)*point;
            double be=entry+(buy ? offset : -offset);
            candidate=buy ? MathMax(candidate,be) :
                            MathMin(candidate,be);
         }
      }

      if(profit>=TslTriggerPoints)
      {
         double trail=market+(buy ? -1.0 : 1.0)*TslPoints*point;
         candidate=buy ? MathMax(candidate,trail) :
                         MathMin(candidate,trail);
      }

      candidate=buy ? Down(MathMin(candidate,market-minimum)) :
                      Up(MathMax(candidate,market+minimum));

      double improvement=buy ? candidate-old_sl : old_sl-candidate;
      bool improve=improvement>=TslStepPoints*point-tick_size*0.1;

      if(!improve)
         candidate=old_sl;

      bool repair_tp=(old_tp<=0 && TpMultiplier>0);
      if(repair_tp)
      {
         double original_distance=MathAbs(entry-old_sl);
         double target=MathMax(original_distance*TpMultiplier,minimum);
         tp=buy ? Up(MathMax(entry+target,market+minimum)) :
                  Down(MathMin(entry-target,market-minimum));
      }

      if(!improve && !repair_tp)
         return;
      if(candidate<=0 || (repair_tp && tp<=0))
         return;

      if(freeze>0)
      {
         if(MathAbs(market-old_sl)<=freeze*point ||
            (old_tp>0 && MathAbs(old_tp-market)<=freeze*point))
            return;
      }

      MqlTradeRequest r;
      MqlTradeResult result;
      Base(r,TRADE_ACTION_SLTP,"PROTECT");
      r.position=ticket;
      r.sl=candidate;
      r.tp=tp;

      if(Send(r,true,result))
         last_trail=now;
   }

   bool Recover()
   {
      if(!HistorySelect(AxMidnight(Now()),Now()))
      {
         Log(0,"HISTORY_FAILED","daily history unavailable");
         return false;
      }

      // Snapshot tickets before any position-specific selection changes
      // the terminal's current history list.
      ulong deals[];
      int n=HistoryDealsTotal();
      ArrayResize(deals,n);
      for(int i=0;i<n;i++)
         deals[i]=HistoryDealGetTicket(i);

      ulong entries[];
      ulong closed_candidates[];
      for(int i=0;i<n;i++)
      {
         ulong d=deals[i];
         if(d==0 || !HistoryDealSelect(d))
            return false;
         if(HistoryDealGetString(d,DEAL_SYMBOL)!=symbol)
            continue;

         long type=HistoryDealGetInteger(d,DEAL_TYPE);
         if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL)
            continue;

         ulong id=(ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID);
         long e=HistoryDealGetInteger(d,DEAL_ENTRY);
         ulong dm=(ulong)HistoryDealGetInteger(d,DEAL_MAGIC);

         if(dm==magic && (e==DEAL_ENTRY_IN || e==DEAL_ENTRY_INOUT))
            AddId(entries,id);

         if(e==DEAL_ENTRY_OUT || e==DEAL_ENTRY_OUT_BY ||
            e==DEAL_ENTRY_INOUT)
            AddId(closed_candidates,id);
      }

      long times[];
      double profits[];

      for(int i=0;i<ArraySize(closed_candidates);i++)
      {
         ulong id=closed_candidates[i];
         if(PositionOpen(id))
            continue;
         if(!HistorySelectByPosition(id))
            return false;

         bool own_entry=false;
         bool foreign_entry=false;
         bool exited=false;
         double net=0.0;
         long end=0;

         int count=HistoryDealsTotal();
         for(int j=0;j<count;j++)
         {
            ulong d=HistoryDealGetTicket(j);
            if(d==0)
               return false;

            long e=HistoryDealGetInteger(d,DEAL_ENTRY);
            long type=HistoryDealGetInteger(d,DEAL_TYPE);
            if(type==DEAL_TYPE_BUY || type==DEAL_TYPE_SELL)
            {
               if(e==DEAL_ENTRY_IN || e==DEAL_ENTRY_INOUT)
               {
                  if((ulong)HistoryDealGetInteger(d,DEAL_MAGIC)==magic)
                     own_entry=true;
                  else
                     foreign_entry=true;
               }

               if(e==DEAL_ENTRY_OUT || e==DEAL_ENTRY_OUT_BY ||
                  e==DEAL_ENTRY_INOUT)
               {
                  exited=true;
                  long t=HistoryDealGetInteger(d,DEAL_TIME_MSC);
                  if(t>end)
                     end=t;
               }
            }

            net+=HistoryDealGetDouble(d,DEAL_PROFIT)+
                 HistoryDealGetDouble(d,DEAL_SWAP)+
                 HistoryDealGetDouble(d,DEAL_COMMISSION)+
                 HistoryDealGetDouble(d,DEAL_FEE);
         }

         if(!own_entry || !exited)
            continue;

         if(foreign_entry && !hedge)
         {
            hard_halt=true;
            cancel_requested=true;
            Log(0,"MIXED_NETTING_HISTORY",
                "another strategy entered managed position="+(string)id);
            continue;
         }

         if(end<(long)AxMidnight(Now())*1000)
            continue;

         int s=ArraySize(times);
         ArrayResize(times,s+1);
         ArrayResize(profits,s+1);
         times[s]=end;
         profits[s]=net;
      }

      for(int i=1;i<ArraySize(times);i++)
      {
         long t=times[i];
         double p=profits[i];
         int j=i-1;
         while(j>=0 && times[j]>t)
         {
            times[j+1]=times[j];
            profits[j+1]=profits[j];
            j--;
         }
         times[j+1]=t;
         profits[j+1]=p;
      }

      for(int i=0;i<ArraySize(entries);i++)
         AddId(seen_positions,entries[i]);

      trades_today=(int)MathMax(trades_today,ArraySize(seen_positions));

      int calculated_losses=0;
      for(int i=0;i<ArraySize(profits);i++)
         calculated_losses=profits[i]<0 ? calculated_losses+1 : 0;

      int closed=ArraySize(times);
      if(closed>0)
      {
         datetime latest=(datetime)(times[closed-1]/1000);
         // Do not let an older/incomplete snapshot erase persisted state.
         if(latest>=last_exit_time)
         {
            losses=calculated_losses;
            last_exit_time=latest;
            int wait=profits[closed-1]<0 ?
                     CooldownAfterLossSecs : CooldownAfterWinSecs;
            cooldown_until=latest+wait;
         }
      }

      if(losses>=MaxConsecutiveLosses)
         streak_trip=true;

      history_dirty=false;
      Persist();
      return true;
   }

   void QueueJournal(const ulong deal)
   {
      if(WriteCsvJournal)
         AddId(journal_queue,deal);
   }

   void FlushJournal()
   {
      if(!WriteCsvJournal || ArraySize(journal_queue)==0)
         return;

      ulong deal=journal_queue[0];
      string marker=Key("J2_"+(string)deal);
      bool done=GlobalVariableCheck(marker);

      if(!done)
      {
         if(!HistoryDealSelect(deal))
            return;

         FolderCreate("Aurex");
         string filename="Aurex\\"+ip+"deals.csv";
         ResetLastError();
         int h=FileOpen(filename,
            FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');

         if(h==INVALID_HANDLE)
         {
            Log(0,"JOURNAL_FAILED",
                "error="+IntegerToString(GetLastError()));
            return;
         }

         if(FileSize(h)==0)
            FileWrite(h,"deal","order","position","time_msc",
               "symbol","magic","entry","volume","price",
               "profit","swap","commission","fee");

         FileWrite(h,
            (string)deal,
            (string)HistoryDealGetInteger(deal,DEAL_ORDER),
            (string)HistoryDealGetInteger(deal,DEAL_POSITION_ID),
            (string)HistoryDealGetInteger(deal,DEAL_TIME_MSC),
            HistoryDealGetString(deal,DEAL_SYMBOL),
            (string)HistoryDealGetInteger(deal,DEAL_MAGIC),
            (string)HistoryDealGetInteger(deal,DEAL_ENTRY),
            DoubleToString(HistoryDealGetDouble(deal,DEAL_VOLUME),8),
            DoubleToString(HistoryDealGetDouble(deal,DEAL_PRICE),digits),
            DoubleToString(HistoryDealGetDouble(deal,DEAL_PROFIT),2),
            DoubleToString(HistoryDealGetDouble(deal,DEAL_SWAP),2),
            DoubleToString(HistoryDealGetDouble(deal,DEAL_COMMISSION),2),
            DoubleToString(HistoryDealGetDouble(deal,DEAL_FEE),2));

         FileClose(h);

         if(GlobalVariableSet(marker,1.0)==0.0)
            return;
      }

      int n=ArraySize(journal_queue);
      for(int i=1;i<n;i++)
         journal_queue[i-1]=journal_queue[i];
      ArrayResize(journal_queue,n-1);
   }
