AUREX HFT v1 — XAUUSD & BTC Low-Latency Scalper
Implementation Brief for the Building Agent
0. Who you are
You are the principal engineer at a small proprietary-trading technology firm, and the sole owner of this build. You have shipped MQL5 Expert Advisors that passed MQL5 Market validation and ran unattended on live ECN accounts for years. You have watched retail "HFT" EAs die from three causes — order-modification throttling, unmodelled commission and slippage, and race conditions between pending-order fills and cancellations — and you design against all three by default.
You are not a code generator taking dictation. Where this brief conflicts with MQL5 capabilities, broker execution mechanics, XAUUSD/BTC microstructure, or sound engineering, you resolve the conflict in favour of reality, document the deviation in DESIGN_DECISIONS.md, and move on. Every design choice you make must be defensible to a sceptical quant reviewer who will ask "what happens when the broker rejects this?" and "what does this cost per trade?"
The product is commercial. Code quality, determinism, and observability are features, not polish.
1. Product definition
Name: Aurex HFT — XAUUSD & BTC Low-Latency Scalper, version 1.00
Platform: MetaTrader 5, pure MQL5, no DLLs (MQL5 Market requirement)
Strategy class: two-sided breakout straddle. A BUY_STOP sits Delta points above Ask and a SELL_STOP Delta points below Bid. Whichever side fills becomes the position; the other side is cancelled instantly. The position exits at a fixed stop, a take profit derived from the stop, or a trailing stop that activates after a profit threshold.
Instruments: XAUUSD on weekdays, BTCUSD on weekends (Saturday 00:00 to Sunday market close, server time). One codebase, symbol-agnostic core, per-symbol profiles.
Target environment: IC Markets Raw / Pepperstone Razor, MT5, low-latency VPS in New York (sub-3 ms round trip to the broker's NY servers).
Hard prohibitions: no martingale, no grid, no averaging into losers, no hedged simultaneous positions, no lot increase after a loss.
Account constraints: must run correctly from a 500 USD balance at 1% risk; must run with defaults, untouched, on first attach.
2. Ground truth you must design around
These are not opinions. Build against them.
MQL5 execution model. An EA is single-threaded. OnTick, OnTimer, OnTradeTransaction run sequentially on one thread; there is no multithreading, and "threading" in the client's request translates to: never block, use OrderSendAsync where the result is not needed synchronously, and keep every handler under a few hundred microseconds of your own CPU time. OnTick events coalesce — if ticks arrive while a handler runs, you receive only the latest. Use SymbolInfoTick for the freshest quote at the moment of decision, never a cached one. EventSetMillisecondTimer gives you a timer with practical resolution of roughly 10–16 ms on Windows, not 1 ms. OnTick fires only for the chart symbol; a second symbol must be polled or given its own chart instance.
Pending stop orders execute at market. When a BUY_STOP triggers on an ECN, the broker fills it at the current market price. The deviation field does not protect a pending order's activation. Slippage on gold breakouts is real and asymmetric (worse in the breakout direction). Your cost model must carry a slippage estimate that is measured from actual fills, not assumed.
Order-modification traffic is finite. Two OrderModify calls per tick on gold during London/NY is dozens of requests per second. The server answers with TRADE_RETCODE_TOO_MANY_REQUESTS, and ECN brokers' terms allow them to treat excessive pending-order modification as abusive. "Re-centre on every tick" therefore means "re-evaluate on every tick, modify only when justified" — see §5.
Stops level and freeze level. SYMBOL_TRADE_STOPS_LEVEL sets the minimum distance for pending orders and SL/TP from the current price; SYMBOL_TRADE_FREEZE_LEVEL sets a band around the price inside which pending orders cannot be modified or deleted. Both are often 0 on Raw accounts but can be non-zero and can change intraday. Read them on every decision, never at init only.
Commission is not a symbol property you can read. There is no reliable MQL5 symbol property for the commission schedule. Take it as an input (CommissionPerLotRoundTurn, default 7.00 USD for gold on the target brokers — the user must confirm), then calibrate it from DEAL_COMMISSION on filled deals and warn if the observed value differs from the input by more than 20%.
Spread is not zero. Read SymbolInfoInteger(SYMBOL_SPREAD) or compute Ask−Bid on every tick. Keep a rolling median and 95th percentile; the filter uses the live value, the cost model uses the median.
Netting vs hedging. ACCOUNT_MARGIN_MODE determines whether an opposite fill would open a second position (hedging) or reverse/close the first (netting). The cross-cancel logic must be correct in both modes and must not rely on the opposite order never filling: two stops can both trigger within one server-side price spike before your cancel arrives. Handle the "both filled" case explicitly (§6.4).
Contract arithmetic. XAUUSD: 1 lot = 100 oz, point = 0.01, so 1 point ≈ 1 USD per lot on a USD account — but compute from SYMBOL_TRADE_TICK_VALUE / SYMBOL_TRADE_TICK_SIZE, never hardcode. BTCUSD: contract size, point, tick value, minimum lot, stops level, commission structure and swap all differ by broker and are frequently different from gold (percentage commission or spread-only pricing is common). Weekend BTC has thinner liquidity and materially wider spreads than weekday BTC; results from weekend BTC testing say nothing about gold performance.
The strategy's edge is not guaranteed. A tight straddle on a noisy instrument is a whipsaw machine unless there is a volatility/momentum gate. The 1% risk budget on a 500 USD account is 5 USD per trade; at a 30-point stop that is 0.16 lots, and commission alone is ~1.12 USD — over 20% of the risk budget before spread or slippage. The EA must compute and display this cost-to-risk ratio and refuse to arm when it exceeds a threshold (§7). Your job is to make the system correct, safe, observable and cheap to run; profitability is proven in testing, not assumed in code.
3. Architecture
Single .mq5 entry file plus an Include/Aurex/ library of .mqh modules. Pure functions where possible; state confined to a small number of explicit objects. Every module has one responsibility and no hidden dependencies on globals.
Aurex_HFT.mq5 // entry: event wiring only Include/Aurex/ Config.mqh // inputs → validated, typed config struct SymbolProfile.mqh // per-symbol runtime facts, refreshed on schedule MarketData.mqh // fresh tick, spread stats, tick-velocity, ATR CostModel.mqh // spread+commission+slippage → points; breakeven, cost ratio RiskEngine.mqh // lot sizing, margin validation, daily circuit breaker Scheduler.mqh // sessions, exclude zones, weekday/weekend symbol gate OrderGeometry.mqh // delta/stop/tp/trail computation, stops/freeze clamping ExecutionEngine.mqh // request builder, OrderCheck, send/async, retcode policy StraddleStateMachine.mqh // IDLE/ARMED/IN_POSITION/COOLDOWN/PAUSED/HALTED PositionManager.mqh // trailing stop, break-even, exits Reconciler.mqh // startup + periodic sync with server state by magic RateLimiter.mqh // token bucket for order traffic Persistence.mqh // day-start equity, counters, across restarts Telemetry.mqh // structured logs, latency histograms, dashboard Licence.mqh // commercial gate (account/expiry), stubbed but wired 
Event wiring:
OnInit: validate inputs, build profile, reconcile with server, start millisecond timer, arm if permitted.
OnTick: refresh market data, run the state machine's OnQuote step (one pass, no loops that wait).
OnTimer (e.g. 50 ms): housekeeping the tick stream cannot guarantee — stale-quote detection, scheduler transitions, daily reset, re-reconcile every N seconds, dashboard refresh at a lower cadence.
OnTradeTransaction: the only place fills and cancellations are recognised. Never infer a fill from polling in OnTick.
OnDeinit: leave server state intact unless CancelPendingsOnDeinit is true; persist counters.
4. Symbol profiles and the two-instrument schedule
Run one EA instance per chart: one on XAUUSD, one on BTCUSD, same compiled file, each with a distinct magic number. The Scheduler decides which instance is active based on server-time day-of-week and the TradeGoldDays / TradeBtcDays masks; the inactive instance sits in PAUSED, holds no orders, and keeps its dashboard alive. Coordinate through terminal global variables namespaced by magic:
AUREX_<magic>_ACTIVE heartbeat, so each instance can see the other.
AUREX_KILL — a single account-level kill switch that halts both.
Daily loss is an account property. Both instances compute it from the same start-of-day equity snapshot persisted under AUREX_DAYSTART_<yyyymmdd>; whichever instance sees the day boundary first writes it.
Do not attempt to trade a second symbol from one chart in v1; document this as the v2 option (a single instance polling both symbols via SymbolInfoTick in OnTimer), and the reason it was deferred (tick coalescing and quote freshness).
SymbolProfile loads on init and refreshes every 60 s and after any INVALID_STOPS/FROZEN retcode: digits, point, tick size/value, contract size, volume min/max/step, stops level, freeze level, execution mode, trade mode, session times, margin rate, and the input commission. Everything downstream consumes the profile, never raw SymbolInfo* calls.
The EA must attach to any symbol without error (MQL5 Market validation runs it on arbitrary symbols/timeframes). On a symbol that is neither the configured gold nor BTC symbol it enters PAUSED with a clear dashboard message and does nothing.
5. Re-centring without getting throttled
Two execution modes, selectable by input, both implemented:
Mode A — SERVER_PENDING (default). Real BUY_STOP/SELL_STOP orders on the server. Re-centring rule: on each quote, compute the ideal levels; modify a side only if all of the following hold:
Its current distance from the market deviates from Delta by more than MaxDistance points (hysteresis band).
At least RecentreMinMs ms have elapsed since that side was last modified.
The new level is outside the freeze level and at or beyond the stops level.
The rate limiter has a token (default budget: 4 modifications/second sustained, burst 8, shared across both sides and all order types).
Modify both sides in one pass when both qualify, SELL_STOP first if price is falling and BUY_STOP first if rising (move the side price is approaching, first). Use OrderSendAsync for modifications; process results in OnTradeTransaction/OnTradeTransaction-delivered TRADE_TRANSACTION_REQUEST and adjust local state only on confirmation.
Mode B — VIRTUAL_STOPS. No pending orders exist on the server. The EA holds the two trigger levels in memory, re-centres them on every tick at zero broker cost, and fires a market order the instant a fresh quote crosses a level, with deviation = Slippage. This trades one round-trip of latency (sub-3 ms on the target VPS) for zero modification traffic and the ability to abort a trigger if the spread has just blown out. Provide a VirtualTriggerConfirmTicks input (default 1) so the user can require two consecutive quotes beyond the level.
Document the trade-off in the user manual: Mode A guarantees the trigger price is honoured server-side (with market slippage on fill); Mode B guarantees no throttling and gives a last-instant spread check.
6. The straddle state machine
States: PAUSED (scheduler/spread/other gate closed), IDLE (may arm), ARMED (both sides live), IN_POSITION, COOLDOWN, HALTED (circuit breaker; manual or next-day reset), RECONCILING (startup or after inconsistency).
6.1 Arming preconditions (all must pass, evaluated fresh from the profile and market data):
Scheduler says active for this symbol and inside session, outside exclude zone.
Live spread ≤ MaxSpreadPoints, and spread has been ≤ MaxSpreadPoints for at least SpreadStableMs.
Quote is fresh: last tick age ≤ MaxQuoteAgeMs.
Volatility gate: ATR(AtrPeriod, M1) in points ≥ MinAtrPoints and ≤ MaxAtrPoints.
Daily circuit breaker not tripped; MaxTradesPerDay and MaxConsecutiveLosses not reached.
Cost model says CostToRiskRatio ≤ MaxCostToRiskRatio (§7).
Margin check passes for the computed lot on both sides simultaneously (only one will fill, but on hedging accounts both pendings may be margin-reserved by some brokers — check the worse case via OrderCalcMargin and OrderCheck).
No existing position or order with this magic on this symbol (else → RECONCILING).
6.2 Order geometry (all in points, all clamped to stops/freeze levels and rounded to tick size):
Buy trigger = Ask + Delta; sell trigger = Bid − Delta. Enforce Delta ≥ max(StopsLevel, MinDeltaPoints).
SL = StopPoints from the trigger price. TP = StopPoints × TpMultiplier. If TpMultiplier = 0, no TP (trailing only).
Hard rule: TP_points − costModel.roundTurnPoints ≥ MinNetTargetPoints, else do not arm and show why.
Attach SL/TP on the pending order itself so the server holds them from the moment of fill (fills on gold can gap through a stop the client would have placed a few ms later).
6.3 Fill handling (OnTradeTransaction, TRADE_TRANSACTION_DEAL_ADD, DEAL_ENTRY_IN, our magic): record fill price, compute realised slippage vs trigger, update the slippage estimator, transition to IN_POSITION, and immediately cancel the opposite pending (Mode A) or disarm the opposite level (Mode B). Do this cancellation synchronously with OrderSend — this is the one place latency matters more than non-blocking.
6.4 Both-sides-filled race. If an opposite DEAL_ENTRY_IN arrives while IN_POSITION: on hedging accounts, close the newer position at market at once and log a RACE_DOUBLE_FILL event; on netting accounts the server already netted — reconcile the resulting position (may be flat or reversed) and treat the outcome as the live position with fresh SL/TP. Count this event; if it happens more than MaxDoubleFillsPerDay times, widen Delta automatically by one MaxDistance step for the rest of the day and warn.
6.5 Exit and cooldown. On DEAL_ENTRY_OUT: record P&L, commission, swap, duration, exit reason (SL/TP/TSL/manual/circuit-breaker), update daily counters, enter COOLDOWN for CooldownAfterWinSecs or CooldownAfterLossSecs, then back to IDLE.
6.6 Trailing stop (PositionManager, every quote while IN_POSITION): once open profit ≥ TslTriggerPoints, move SL to price − TslPoints (long) / price + TslPoints (short), only if it improves by ≥ TslStepPoints and respects stops/freeze levels and the rate limiter, and never more than once per TslMinIntervalMs. Optional BreakEvenAtPoints moves SL to entry + costs first. Use PositionModify; confirm via transaction, never assume.
7. Cost model and lot sizing
tickValuePerPointPerLot = SYMBOL_TRADE_TICK_VALUE × (SYMBOL_POINT / SYMBOL_TRADE_TICK_SIZE) commissionPoints = CommissionPerLotRoundTurn / tickValuePerPointPerLot roundTurnPoints = medianSpreadPoints + commissionPoints + 2 × expectedSlippagePoints breakevenMovePoints = roundTurnPoints grossRiskPoints = StopPoints + expectedSlippagePoints riskMoney = riskBase × RiskPercent / 100 // riskBase per LotSizingMode lots = riskMoney / (grossRiskPoints × tickValuePerPointPerLot + CommissionPerLotRoundTurn) lots = floor to SYMBOL_VOLUME_STEP, clamp to [VOLUME_MIN, VOLUME_MAX], then margin-clamp costToRiskRatio = (roundTurnPoints × tickValuePerPointPerLot × lots) / riskMoney 
Notes the implementation must honour: include commission inside the risk denominator so 1% risk means 1% including costs; expectedSlippagePoints starts at InitialSlippageEstimatePoints and becomes an EWMA of observed fill slippage after 10 fills; lot sizing modes are FIXED, PCT_BALANCE, PCT_EQUITY, PCT_FREE_MARGIN; if the margin-clamped lot is below VOLUME_MIN the EA does not trade and says so on the dashboard. Margin validation = OrderCalcMargin for the side, compared against ACCOUNT_MARGIN_FREE × (1 − MarginBufferPercent/100), then OrderCheck on the fully built request as the final gate.
8. Risk controls
Daily loss circuit breaker: realised + unrealised P&L since start-of-day equity ≤ −DailyLossLimitPercent × dayStartEquity → cancel all pendings, optionally close the open position (CloseOnCircuitBreaker), enter HALTED until the next server day. Persist day-start equity and trip state so a terminal restart mid-day cannot reset the breaker.
Daily profit lock (optional): DailyProfitTargetPercent > 0 halts new trades after reaching it.
MaxTradesPerDay, MaxConsecutiveLosses, MaxOpenPositions = 1 (not configurable).
Stale quote guard: no arming/modifying if the last tick is older than MaxQuoteAgeMs; if in position and quotes stall > QuoteStallCloseMs, log and hold (do not blind-close into a stalled feed).
Connection guard: TERMINAL_CONNECTED false → PAUSED; on reconnect → RECONCILING.
Kill switch: global variable AUREX_KILL and a dashboard button.
9. Execution engine and retcode policy
Build every MqlTradeRequest through one function that fills type_filling from SYMBOL_FILLING_MODE (prefer FOK, fall back to IOC, then RETURN), type_time = ORDER_TIME_GTC for pendings, deviation = Slippage, magic, comment = "AUREX1|<state>|<side>". Run OrderCheck before every send. Retcode handling table (implement as a switch, not scattered ifs):
Retcode Policy
DONE / PLACED / DONE_PARTIAL confirm state on transaction; partial → track remaining
REQUOTE / PRICE_CHANGED / PRICE_OFF refresh quote, rebuild, retry ≤ 2 within 50 ms
INVALID_STOPS / INVALID_PRICE refresh profile, re-clamp geometry, retry once
FROZEN do not retry this tick; retry on next qualifying quote
TOO_MANY_REQUESTS back off exponentially (200 ms → 3.2 s), halve rate budget for 60 s
NO_MONEY recompute lots; if still failing → PAUSED with reason
MARKET_CLOSED / TRADE_DISABLED PAUSED, re-check on timer
CONNECTION / TIMEOUT RECONCILING on reconnect
anything else log full request + response, PAUSED, no blind retries


Wrap every send with GetMicrosecondCount() and keep p50/p95/p99 latency histograms per request type on the dashboard and in the log.
10. Reconciliation and persistence
On init, after reconnect, and every ReconcileIntervalSecs: enumerate orders and positions for this symbol+magic. Rebuild the state machine from what the server shows: one position → IN_POSITION; two pendings → ARMED; one pending and no position → cancel it, IDLE; anything else → cancel all pendings, IDLE, log RECONCILE_ANOMALY. Local state never overrides server state.
Persist day-start equity, daily counters, trip state, slippage EWMA and observed commission in terminal global variables (fast, survive restart) with a file backup in MQL5/Files/Aurex/.
11. Inputs
Group and name exactly as below; every input gets a comment string that appears in the MT5 inputs dialog. Defaults must produce a safe, functioning configuration on XAUUSD Raw/Razor with a 500 USD account. The agent picks defaults and justifies each in DESIGN_DECISIONS.md.
Identity & Execution: MagicNumberGold, MagicNumberBtc, ExecutionMode (SERVER_PENDING / VIRTUAL_STOPS), Slippage (points, market orders only), CommissionPerLotRoundTurn (USD), CancelPendingsOnDeinit.
Symbols & Schedule: GoldSymbol (auto-detect from chart if blank), BtcSymbol, TradeGoldDays (bitmask, default Mon–Fri), TradeBtcDays (default Sat–Sun), StartHour, EndHour, ExcludeStartHour, ExcludeEndHour, FridayCloseHour (flatten gold before weekend), SundayCloseHour (flatten BTC before gold session).
Position Sizing: LotSizingMode, FixedLot, RiskPercent (default 1.0), MarginBufferPercent, MaxLot.
Risk Control: DailyLossLimitPercent, CloseOnCircuitBreaker, DailyProfitTargetPercent, MaxTradesPerDay, MaxConsecutiveLosses, MaxCostToRiskRatio, MaxDoubleFillsPerDay.
Order Geometry: DeltaPoints, MaxDistancePoints, RecentreMinMs, StopPoints, TpMultiplier, MinNetTargetPoints, MaxSpreadPoints, SpreadStableMs, MaxQuoteAgeMs.
Volatility Gate: AtrPeriod, MinAtrPoints, MaxAtrPoints, CooldownAfterWinSecs, CooldownAfterLossSecs, VirtualTriggerConfirmTicks.
Trailing: TslTriggerPoints, TslPoints, TslStepPoints, TslMinIntervalMs, BreakEvenAtPoints.
Traffic & Telemetry: MaxRequestsPerSecond, BurstRequests, ReconcileIntervalSecs, ShowDashboard, LogLevel, WriteCsvJournal.
Validate every input in OnInit; on an invalid combination return INIT_PARAMETERS_INCORRECT with a message that says which parameter and why. The client's original names (Delta, Stop, Secs, Max Distance, Max Trailing, etc.) map onto the above; keep a mapping table in the manual.
12. Telemetry and dashboard
Chart panel (drawn with objects, refreshed at ≤ 4 Hz, never per tick): state, symbol, active/paused reason, live spread vs max, ATR vs gate, computed lots, cost-to-risk ratio, round-turn cost in points and USD, day P&L vs limit, trades today, consecutive losses, slippage EWMA, observed vs input commission, request latency p50/p95, rate-limiter headroom, kill button.
Structured log lines (key=value pairs, one event per line) at LogLevel; a CSV journal per day with one row per fill and per exit including trigger price, fill price, slippage, spread at trigger, commission, duration and exit reason. This journal is the input to the profitability analysis the client will run — make it complete.
13. Testing and validation plan (deliver the results, not just the code)
Compile with zero warnings at the strictest level.
Unit-style tests as a script (Aurex_SelfTest.mq5) for CostModel, lot sizing, geometry clamping, and the state machine transitions, using injected profiles for XAUUSD and BTCUSD and for hedging vs netting accounts.
Strategy Tester, "Every tick based on real ticks", on the broker's own XAUUSD history, minimum 3 months, with the tester's commission verified to appear in deals (if the broker profile does not carry commission into the tester, the CostModel must be applied to reported results, and you state this). Report: net P&L after costs, profit factor, max drawdown, average slippage assumed, trades/day, cost as % of gross. Run at 1 ms, 5 ms and 20 ms simulated execution delay. If the strategy is not net-positive after costs with realistic delay, say so plainly in the report — do not tune inputs on the test set to manufacture a curve.
Weekend BTC forward test on the client's Razor demo: this validates plumbing (fills, cancels, trailing, reconciliation, rate limiting, dashboard), not edge. Say so in the report.
Fault injection: disconnect the terminal mid-ARMED, restart mid-IN_POSITION, force a TOO_MANY_REQUESTS by lowering the limiter to zero, and simulate a double fill. Each must end in a consistent reconciled state with a logged event.
MQL5 Market dry run: attach with defaults on EURUSD H1, an index CFD, and a symbol with SYMBOL_TRADE_MODE_DISABLED; no errors, no orders, clear paused reason.
14. Deliverables
Source tree as in §3, compiled .ex5, Aurex_SelfTest.mq5.
DESIGN_DECISIONS.md: every deviation from the client's original concept, with the reason; default-value justifications; known limitations; the v2 roadmap (single-instance dual-symbol polling, news-calendar gate via CalendarValueHistory, adaptive Delta from realised volatility, licence server).
USER_MANUAL.md: installation, per-broker setup for IC Markets Raw and Pepperstone Razor, input reference with the original-name mapping, what each dashboard field means, and a plain-language section titled "What this EA cannot protect you from" (gaps, LP slippage, weekend BTC liquidity, broker throttling if the user lowers RecentreMinMs).
TEST_REPORT.md with the results from §13.
15. Acceptance criteria
The build is accepted when all of the following are demonstrably true:
Never more than one open position per instance; opposite side cancelled or disarmed within one event cycle of a fill; double fills handled per §6.4.
No order request is ever sent without passing OrderCheck, the margin buffer and the rate limiter.
No NO_MONEY, INVALID_STOPS or TOO_MANY_REQUESTS occurs in a 48-hour demo forward test under default settings.
Daily circuit breaker survives terminal restart and trips at the configured level to within one tick of P&L.
Dashboard shows cost-to-risk ratio and refuses to arm above the threshold.
Attaches to any symbol without error; passes the §13.6 dry run.
Every fill and exit appears in the CSV journal with slippage and commission populated from the deal, not estimated.
TEST_REPORT.md states the after-cost result truthfully, including if it is negative.
Begin by reading this brief end to end, list any point you intend to deviate from and why, then produce the architecture skeleton (all files, all public function signatures, the state machine as a table) before writing implementation code.

Here's an example of a Commercial MT4/MT5 "HFT" Tick Scalper
These are built for retail MetaTrader platforms. They do not look at indicators; they read the raw tick flow and place rapid breakout pending orders that dynamically trail the current bid/ask price.
Gold HFT Scalper Pro: A highly searched MT4/MT5 commercial EA tailored specifically for Gold (XAUUSD). It uses tick-level re-centering to place dynamic BUY_STOP and SELL_STOP orders fractions of a pip away from the active market price. It relies on explosive velocity to hit micro-take-profits instantly.
https://www.mql5.com/en/market/product/175790#!tab=overview