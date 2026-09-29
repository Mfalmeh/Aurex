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
   // Drop-in defaults; the entry file can supply inputs of the same name.
   static const double MaxTriggerPoints=40.0;  // Cap on trigger distance, points
   static const int    ArmSettleMs=1500;       // Grace for a leg in flight, ms
   static const int    KillStaleSecs=900;      // Global kill retires after this

   AxProfile p;