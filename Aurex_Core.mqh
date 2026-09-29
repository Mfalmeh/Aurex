#ifndef AUREX_CORE_MQH
#define AUREX_CORE_MQH

#define AX_VERSION "1.00"

enum AX_EXECUTION_MODE
{
   SERVER_PENDING = 0,
   VIRTUAL_STOPS  = 1
};

enum AX_LOT_MODE
{
   FIXED           = 0,
   PCT_BALANCE     = 1,
   PCT_EQUITY      = 2,
   PCT_FREE_MARGIN = 3
};

enum AX_STATE
{
   AX_PAUSED = 0,
   AX_IDLE,
   AX_ARMED,
   AX_IN_POSITION,
   AX_COOLDOWN,
   AX_HALTED,
   AX_RECONCILING
};

string AxStateName(const AX_STATE state)
{
   switch(state)
   {
      case AX_PAUSED:       return "PAUSED";
      case AX_IDLE:         return "IDLE";
      case AX_ARMED:        return "ARMED";
      case AX_IN_POSITION:  return "IN_POSITION";
      case AX_COOLDOWN:     return "COOLDOWN";
      case AX_HALTED:       return "HALTED";
      case AX_RECONCILING:  return "RECONCILING";
   }
   return "UNKNOWN";
}

double AxFloorVolume(const double value,const double step)
{
   if(step<=0.0 || value<=0.0)
      return 0.0;

   return NormalizeDouble(MathFloor(value/step+1e-9)*step,8);
}

double AxRoundUp(const double price,const double tick_size)
{
   if(tick_size<=0.0)
      return price;

   return MathCeil(price/tick_size-1e-9)*tick_size;
}

double AxRoundDown(const double price,const double tick_size)
{
   if(tick_size<=0.0)
      return price;

   return MathFloor(price/tick_size+1e-9)*tick_size;
}

int AxDateKey(const datetime when)
{
   MqlDateTime t;
   TimeToStruct(when,t);
   return t.year*10000+t.mon*100+t.day;
}

datetime AxDayStart(const datetime when)
{
   MqlDateTime t;
   TimeToStruct(when,t);
   t.hour=0;
   t.min=0;
   t.sec=0;
   return StructToTime(t);
}

bool AxHourWindow(const int hour,const int start_hour,const int end_hour)
{
   if(start_hour==end_hour)
      return true;

   if(start_hour<end_hour)
      return hour>=start_hour && hour<end_hour;

   return hour>=start_hour || hour<end_hour;
}

struct AxGeometry
{
   double buy;
   double sell;
   double buy_sl;
   double sell_sl;
   double buy_tp;
   double sell_tp;
   double stop_points;
   double delta_points;
};

struct AxCosts
{
   double point_value;
   double commission_points;
   double round_turn_points;
   double risk_money;
   double lots;
   double ratio;
   double cash_cost;
};

class AxProfile
{
public:
   string symbol;
   int digits;
   double point;
   double tick_size;
   double tick_value;
   double tick_value_loss;
   double contract;
   double volume_min;
   double volume_max;
   double volume_step;
   int stops;
   int freeze;
   long filling;
   long execution;
   long trade_mode;
   long order_mode;
   long expiration_mode;
   datetime refreshed;

   bool Refresh(const string name)
   {
      symbol=name;

      if(!SymbolSelect(symbol,true))
         return false;

      digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      point=SymbolInfoDouble(symbol,SYMBOL_POINT);
      tick_size=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
      tick_value=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
      tick_value_loss=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
      contract=SymbolInfoDouble(symbol,SYMBOL_TRADE_CONTRACT_SIZE);
      volume_min=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
      volume_max=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
      volume_step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);

      filling=SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
      execution=SymbolInfoInteger(symbol,SYMBOL_TRADE_EXEMODE);
      trade_mode=SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE);
      order_mode=SymbolInfoInteger(symbol,SYMBOL_ORDER_MODE);
      expiration_mode=SymbolInfoInteger(symbol,SYMBOL_EXPIRATION_MODE);

      RefreshDistances();
      refreshed=TimeCurrent();

      return point>0.0 && tick_size>0.0 &&
             volume_min>0.0 && volume_step>0.0;
   }

   bool RefreshDistances()
   {
      stops=(int)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
      freeze=(int)SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL);
      trade_mode=SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE);

      // Tick values can change with conversion rates.
      tick_value=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
      tick_value_loss=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);

      return point>0.0;
   }

   double PointValue()
   {
      if(tick_size<=0.0)
         return 0.0;

      return tick_value*point/tick_size;
   }

   double LossPointValue()
   {
      if(tick_size<=0.0)
         return 0.0;

      double v=MathMax(tick_value,tick_value_loss);
      return v*point/tick_size;
   }

   ENUM_ORDER_TYPE_FILLING MarketFilling()
   {
      if((filling & SYMBOL_FILLING_FOK)!=0)
         return ORDER_FILLING_FOK;

      if((filling & SYMBOL_FILLING_IOC)!=0)
         return ORDER_FILLING_IOC;

      // RETURN is not allowed for Market Execution.
      if(execution==SYMBOL_TRADE_EXECUTION_MARKET)
         return ORDER_FILLING_FOK;

      return ORDER_FILLING_RETURN;
   }

   bool SessionOpen(const datetime now)
   {
      MqlDateTime t;
      TimeToStruct(now,t);

      int second=t.hour*3600+t.min*60+t.sec;
      datetime from=0,to=0;
      bool found=false;

      for(uint i=0;i<32;i++)
      {
         if(!SymbolInfoSessionTrade(symbol,
              (ENUM_DAY_OF_WEEK)t.day_of_week,i,from,to))
            break;

         found=true;
         int a=(int)((long)from%86400);
         int b=(int)((long)to%86400);

         if(a==b)
            return true;

         if(a<b && second>=a && second<b)
            return true;

         if(a>b && (second>=a || second<b))
            return true;
      }

      // Unknown sessions do not authorize a trade.
      return found ? false : false;
   }

   bool StopOrdersAllowed()
   {
      return (order_mode & SYMBOL_ORDER_STOP)!=0 &&
             (order_mode & SYMBOL_ORDER_SL)!=0;
   }
};

class AxMarket
{
private:
   string m_symbol;
   int m_atr;
   double m_spreads[256];
   int m_count;
   int m_next;
   long m_last_tick_msc;
   ulong m_seen_local;
   ulong m_stable_since;
   bool m_stable;

public:
   MqlTick tick;
   double spread;
   double atr_points;
   double previous_mid;
   bool new_tick;

   bool Init(const string symbol,const int atr_period)
   {
      m_symbol=symbol;
      m_atr=iATR(symbol,PERIOD_M1,atr_period);
      m_count=0;
      m_next=0;
      m_last_tick_msc=0;
      m_seen_local=GetTickCount64();
      m_stable_since=0;
      m_stable=false;
      spread=0.0;
      atr_points=0.0;
      previous_mid=0.0;
      new_tick=false;
      ZeroMemory(tick);

      return m_atr!=INVALID_HANDLE;
   }

   void Release()
   {
      if(m_atr!=INVALID_HANDLE)
         IndicatorRelease(m_atr);

      m_atr=INVALID_HANDLE;
   }

   bool Read(AxProfile &p,const int max_spread)
   {
      MqlTick fresh;
      if(!SymbolInfoTick(m_symbol,fresh))
         return false;

      if(fresh.bid<=0.0 || fresh.ask<fresh.bid || p.point<=0.0)
         return false;

      previous_mid=(tick.ask+tick.bid)*0.5;
      tick=fresh;
      new_tick=(tick.time_msc!=m_last_tick_msc);
      spread=(tick.ask-tick.bid)/p.point;

      if(new_tick)
      {
         m_last_tick_msc=tick.time_msc;
         m_seen_local=GetTickCount64();

         m_spreads[m_next]=spread;
         m_next=(m_next+1)%256;
         if(m_count<256)
            m_count++;

         if(spread<=max_spread)
         {
            if(!m_stable)
            {
               m_stable=true;
               m_stable_since=GetTickCount64();
            }
         }
         else
         {
            m_stable=false;
            m_stable_since=0;
         }
      }

      return true;
   }

   void RefreshAtr(AxProfile &p)
   {
      if(m_atr==INVALID_HANDLE || p.point<=0.0)
         return;

      double values[1];

      // Closed M1 bar: stable input rather than a moving intrabar ATR.
      if(CopyBuffer(m_atr,0,1,1,values)==1)
         atr_points=values[0]/p.point;
   }

   double Percentile(const double fraction)
   {
      if(m_count<=0)
         return spread;

      double values[];
      ArrayResize(values,m_count);

      for(int i=0;i<m_count;i++)
         values[i]=m_spreads[i];

      ArraySort(values);
      int index=(int)MathFloor((m_count-1)*fraction);
      return values[index];
   }

   double Median() { return Percentile(0.50); }
   double P95()    { return Percentile(0.95); }

   bool Stable(const int milliseconds)
   {
      return m_stable &&
             GetTickCount64()-m_stable_since>=(ulong)milliseconds;
   }

   long QuoteAgeMs()
   {
      long local_age=(long)(GetTickCount64()-m_seen_local);

      // TimeCurrent is server quote time, not workstation wall time.
      long server_age=(long)TimeCurrent()*1000-tick.time_msc;
      if(server_age<0)
         server_age=0;

      return (long)MathMax((double)local_age,(double)server_age);
   }
};

class AxLimiter
{
private:
   double m_rate;
   double m_capacity;
   double m_tokens;
   ulong m_last;
   ulong m_block_until;
   ulong m_reduced_until;
   int m_backoff;

   void Refill()
   {
      ulong now=GetTickCount64();
      double rate=m_rate;

      if(now<m_reduced_until)
         rate*=0.5;

      m_tokens=MathMin(m_capacity,
                      m_tokens+(now-m_last)*rate/1000.0);
      m_last=now;
   }

public:
   void Init(const double rate,const double burst)
   {
      m_rate=rate;
      m_capacity=burst;
      m_tokens=burst;
      m_last=GetTickCount64();
      m_block_until=0;
      m_reduced_until=0;
      m_backoff=0;
   }

   bool Take(const bool maintenance)
   {
      Refill();

      if(GetTickCount64()<m_block_until)
         return false;

      // Keep one token available for cancellation/closure when possible.
      double required=maintenance ? 1.0 : 2.0;

      if(m_tokens+1e-9<required)
         return false;

      m_tokens-=1.0;
      return true;
   }

   void Penalize()
   {
      ulong now=GetTickCount64();

      if(now>=m_reduced_until)
         m_backoff=0;

      m_backoff=(m_backoff==0 ? 200 : (int)MathMin(3200,m_backoff*2));
      m_block_until=now+(ulong)m_backoff;
      m_reduced_until=now+60000;
   }

   double Headroom()
   {
      Refill();
      return m_tokens;
   }
};

#endif
// ==================== END OF FILE: Aurex_Core.mqh ====================
