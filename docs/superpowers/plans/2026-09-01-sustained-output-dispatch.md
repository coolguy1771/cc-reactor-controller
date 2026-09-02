# Sustained Output Dispatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Control every connected Extreme Reactors device independently to maximize sustained RF/t while throttling to demand as finite power storage fills.

**Architecture:** Each tick produces one cached set of device readings. A storage coordinator derives external demand and reserve pressure, then a pure dispatcher assigns explicit RF/t and steam/t targets by usable device capacity. Reactor and turbine actuators follow those targets while the existing safety state machine and per-tick turbine governor retain higher priority.

**Tech Stack:** Lua 5.3/5.4, CC:Tweaked peripherals, Extreme Reactors Modernized Object API, existing headless ComputerCraft simulator.

**Spec:** `docs/superpowers/specs/2026-09-01-sustained-output-dispatch-design.md`

## Global Constraints

- Target All the Mods 10 version 7.2 on Minecraft 1.21.1/NeoForge.
- Optimize maximum sustained RF/t, not fuel economy or short flywheel bursts.
- Throttle generation to external demand when storage cannot absorb surplus power.
- Keep SCRAM, thermal, steam, invalid-reading, watchdog, and absolute-RPM protections above dispatch.
- Read each peripheral getter no more than once per control tick and retain setter deadbands.
- Preserve existing config files, entity overrides, steam groups, remote displays, transactional updater, rollback, and wget role installation.
- Use these defaults: `storageTargetMin=50`, `storageTargetMax=85`, `storageReserveGain=0.25`, `dispatchRebalanceThreshold=0.02`, `capacityLearningRate=0.05`, `sustainedOverspeedEnabled=true`, `sustainedOverspeedLimitRPM=2400`, and `storageExclusions={}`.
- Never use an infinite RPM ceiling for sustained unattended operation.

---

### Task 1: Storage snapshot and demand estimation

**Files:**
- Create: `src/services/storage.lua`
- Create: `test/storage.lua`
- Modify: `src/config/projectConfigs.lua:92-125`

**Interfaces:**
- Consumes: `StorageCoordinator:update(input, config)`, where `input` has `sources`, `actualGeneration`, `availableGeneration`, and `topologyRevision`.
- Produces: `_G.StorageCoordinator.new()` and an immutable-by-convention snapshot with `stored`, `capacity`, `fillPct`, `delta`, `externalDemand`, `reserveFactor`, `rechargeCorrection`, `requiredGeneration`, `trustworthy`, and `sourceIDs`.
- Produces config keys exactly matching the defaults in Global Constraints.

- [ ] **Step 1: Write the failing storage behavior test**

```lua
-- test/storage.lua
dofile("src/services/storage.lua")

local function near(actual, expected, tolerance, label)
    assert(math.abs(actual - expected) <= tolerance,
        string.format("%s: expected %.3f, got %.3f", label, expected, actual))
end

local cfg = {
    storageTargetMin = 50, storageTargetMax = 85,
    storageReserveGain = 0.25, storageExclusions = { ignored = true },
}
local storage = StorageCoordinator.new()

local first = storage:update({
    sources = {
        { id="battery", stored=500, capacity=1000, valid=true },
        { id="ignored", stored=1000, capacity=1000, valid=true },
    },
    actualGeneration = 200, availableGeneration = 1000, topologyRevision = 1,
}, cfg)
assert(first.stored == 500 and first.capacity == 1000, "excluded storage was counted")
assert(first.delta == 0 and first.externalDemand == 200, "first sample did not establish a baseline")

local charging = storage:update({
    sources = { { id="battery", stored=550, capacity=1000, valid=true } },
    actualGeneration = 200, availableGeneration = 1000, topologyRevision = 1,
}, cfg)
near(charging.externalDemand, 150, 0.001, "demand subtracts positive storage delta")
near(charging.reserveFactor, 30 / 35, 0.001, "reserve factor tapers through target band")
near(charging.rechargeCorrection, 182.142857, 0.001, "bounded recharge correction")
near(charging.requiredGeneration, 332.142857, 0.001, "required generation")

local full = storage:update({
    sources = { { id="battery", stored=1000, capacity=1000, valid=true } },
    actualGeneration = 200, availableGeneration = 1000, topologyRevision = 1,
}, cfg)
assert(full.reserveFactor == 0 and full.rechargeCorrection == 0, "full storage requested surplus")

local changed = storage:update({
    sources = { { id="replacement", stored=100, capacity=5000, valid=true } },
    actualGeneration = 300, availableGeneration = 1000, topologyRevision = 2,
}, cfg)
assert(changed.delta == 0 and changed.externalDemand == 300, "topology change created false demand")

print("storage tests passed")
```

- [ ] **Step 2: Run the test and verify the missing service fails**

Run: `lua test/storage.lua`

Expected: FAIL because `src/services/storage.lua` does not exist.

- [ ] **Step 3: Implement storage aggregation and reserve control**

```lua
-- src/services/storage.lua
local Storage = {}
Storage.__index = Storage

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

function Storage.new()
    return setmetatable({ previousStored = nil, topologyRevision = nil }, Storage)
end

function Storage:update(input, config)
    local excluded = config.storageExclusions or {}
    local stored, capacity, ids = 0, 0, {}
    for _, source in ipairs(input.sources or {}) do
        if source.valid ~= false and not excluded[source.id]
            and type(source.stored) == "number" and type(source.capacity) == "number"
            and source.stored >= 0 and source.capacity > 0 then
            stored = stored + source.stored
            capacity = capacity + source.capacity
            ids[#ids + 1] = source.id
        end
    end
    table.sort(ids)

    local topologyChanged = self.topologyRevision ~= input.topologyRevision
    local delta = (not topologyChanged and self.previousStored) and (stored - self.previousStored) or 0
    local actual = math.max(0, input.actualGeneration or 0)
    local demand = math.max(0, actual - delta)
    local fill = capacity > 0 and clamp(stored / capacity * 100, 0, 100) or 0
    local low, high = config.storageTargetMin or 50, config.storageTargetMax or 85
    local reserve = fill < low and 1 or (fill < high and (high - fill) / (high - low) or 0)
    local available = math.max(0, input.availableGeneration or actual)
    local correction = math.max(0, available - demand) * (config.storageReserveGain or 0.25) * reserve

    self.previousStored = stored
    self.topologyRevision = input.topologyRevision
    return {
        stored=stored, capacity=capacity, fillPct=fill, delta=delta,
        externalDemand=demand, reserveFactor=reserve,
        rechargeCorrection=correction, requiredGeneration=demand + correction,
        trustworthy=capacity > 0, sourceIDs=ids,
    }
end

_G.StorageCoordinator = { new = Storage.new }
```

Add the eight approved defaults to `CONTROL_CONFIG` beside the existing storage and responsiveness settings.

- [ ] **Step 4: Run the focused test and full existing suite**

Run: `lua test/storage.lua`

Expected: `storage tests passed`.

Run: `lua test/sim.lua && lua test/remote_server.lua && lua test/remote_client.lua && lua test/watchdog.lua`

Expected: all existing checks pass.

- [ ] **Step 5: Commit the storage service**

```bash
git add src/services/storage.lua src/config/projectConfigs.lua test/storage.lua
git commit -m "feat: derive demand from aggregate storage"
```

### Task 2: Pure capacity-weighted dispatcher

**Files:**
- Create: `src/services/dispatcher.lua`
- Create: `test/dispatcher.lua`

**Interfaces:**
- Consumes: `Dispatcher.allocate(input, config)` with `requiredRF`, `passiveReactors`, `turbines`, `activeReactors`, and `steamGroups`.
- Produces: `{ reactors, turbines, requiredRF, availableRF, saturation }`.
- Reactor targets are `{ unit="rf"|"steam", target=number }`.
- Turbine targets are `{ rfTarget=number, flowTarget=number, rpmLimit=number }`.
- Produces: `Dispatcher.learnCapacity(previous, observation, config)` returning `{ value, known, misses }` without mutating its inputs.
- `input.previousTargets` is optional; when supplied, target changes smaller than
  `capacity * dispatchRebalanceThreshold` retain the previous target, except exact zero and
  full-capacity edges.

- [ ] **Step 1: Write failing allocation and learning tests**

```lua
-- test/dispatcher.lua
dofile("src/services/dispatcher.lua")

local result = Dispatcher.allocate({
    requiredRF = 300,
    passiveReactors = {
        { id="small", capacity=100, weight=1, available=true },
        { id="large", capacity=300, weight=1, available=true },
    },
    turbines = {}, activeReactors = {}, steamGroups = {},
}, { sustainedOverspeedLimitRPM=2400 })
assert(result.reactors.small.target == 75, "small reactor target was not capacity weighted")
assert(result.reactors.large.target == 225, "large reactor target was not capacity weighted")
assert(result.availableRF == 400 and result.saturation == 0.75, "aggregate dispatch summary is wrong")

local stable = Dispatcher.allocate({
    requiredRF = 304, previousTargets = { reactors={ small=75, large=225 }, turbines={} },
    passiveReactors = {
        { id="small", capacity=100, weight=1, available=true },
        { id="large", capacity=300, weight=1, available=true },
    },
    turbines = {}, activeReactors = {}, steamGroups = {},
}, { dispatchRebalanceThreshold=0.02, sustainedOverspeedLimitRPM=2400 })
assert(stable.reactors.small.target == 75 and stable.reactors.large.target == 225,
    "sub-threshold rebalance changed device targets")

local steam = Dispatcher.allocate({
    requiredRF = 100,
    passiveReactors = {},
    turbines = {
        { id="t1", capacity=100, maxFlow=2000, rfPerSteam=0.05, groupId="g", available=true },
    },
    activeReactors = {
        { id="r1", capacity=600, groupId="g", available=true },
        { id="r2", capacity=400, groupId="g", available=true },
    },
    steamGroups = { g={ steamCorrection=0 } },
}, { sustainedOverspeedLimitRPM=2400 })
assert(steam.turbines.t1.rfTarget == 100 and steam.turbines.t1.flowTarget == 2000,
    "turbine RF target was not converted to flow")
assert(steam.reactors.r1.target == 600 and steam.reactors.r2.target == 400,
    "steam reactor targets were not capacity weighted")

local learned = Dispatcher.learnCapacity(
    { value=80, known=true, misses=0 },
    { actual=100, target=100, ceiling=200, steady=true, transient=false },
    { capacityLearningRate=0.05 })
assert(math.abs(learned.value - 81) < 0.001, "capacity EWMA is wrong")

local configured = Dispatcher.learnCapacity(nil,
    { configured=500, actual=10, target=10, steady=true },
    { capacityLearningRate=0.05 })
assert(configured.value == 500 and configured.known, "configured capacity was not authoritative")

print("dispatcher tests passed")
```

- [ ] **Step 2: Run the dispatcher test and verify it fails**

Run: `lua test/dispatcher.lua`

Expected: FAIL because `src/services/dispatcher.lua` does not exist.

- [ ] **Step 3: Implement proportional allocation and bounded learning**

Implement `effectiveCapacity = max(0, capacity) * max(0, weight or 1)`, allocate every electrical source at the same utilization `min(1, requiredRF / totalEffectiveCapacity)`, convert turbine RF to flow with `rfTarget / rfPerSteam` clamped to `maxFlow`, and allocate each steam group's summed turbine flow plus `steamCorrection` across its active reactors at equal capacity utilization. Unavailable devices receive no target.

Implement learning with these exact rules, and apply the previous-target deadband after raw
allocation but before returning targets:

```lua
function Dispatcher.learnCapacity(previous, observation, config)
    if observation.configured then
        return { value=observation.configured, known=true, misses=0 }
    end
    previous = previous or { value=math.max(1, observation.actual or 0), known=false, misses=0 }
    if observation.transient or not observation.steady then return previous end
    local actual, target = math.max(0, observation.actual or 0), math.max(0, observation.target or 0)
    local ceiling = observation.ceiling or math.huge
    local alpha = config.capacityLearningRate or 0.05
    local value, misses = previous.value, previous.misses or 0
    if target > 0 and actual >= target * 0.95 then
        value = math.min(ceiling, value + alpha * (math.max(actual, target) - value))
        misses = 0
    elseif target > value * 0.9 and actual < target * 0.8 then
        misses = misses + 1
        if misses >= 3 then value, misses = math.max(1, actual), 0 end
    end
    return { value=value, known=previous.known or actual > 0, misses=misses }
end
```

- [ ] **Step 4: Run focused and storage tests**

Run: `lua test/dispatcher.lua && lua test/storage.lua`

Expected: both scripts print their passing summaries.

- [ ] **Step 5: Commit the dispatcher**

```bash
git add src/services/dispatcher.lua test/dispatcher.lua
git commit -m "feat: allocate per-device output targets"
```

### Task 3: Single-read device sampling and capacity observations

**Files:**
- Modify: `src/classes/reactor.lua:84-195,420-477`
- Modify: `src/classes/turbine.lua:46-111,243-304`
- Modify: `src/classes/energybuffer.lua:33-89`
- Create: `test/device_sampling.lua`

**Interfaces:**
- Reactor instances expose `energyStored`, `energyCapacity`, `capacityRF`, `capacitySteam`, `capacityKnown`, and `dispatchTarget`.
- Turbine instances expose `capacityRF`, `capacityKnown`, `rfPerSteam`, `bestSustainedRPM`, and `dispatchTarget`.
- Both classes produce `observeCapacity(target, context, config)` and consume `Dispatcher.learnCapacity`.
- `EnergyBuffer.newForgeEnergyBuffer(id)` continues to expose one external storage sample, calling each Forge getter once.

- [ ] **Step 1: Write the failing one-read sampling test**

Create ATM10-style fake reactor and turbine peripherals with counters on every getter. Construct the real `Reactor` and `Turbine`, reset the counters, call `update(1)` twice, and assert each getter count is exactly one. Include this critical assertion:

```lua
assert(calls.reactorEnergyStats == 1,
    "reactor getEnergyStats must provide output, stored RF, and capacity in one call")
assert(calls.turbineEnergyProduced == 1 and calls.turbineEnergyStored == 1
    and calls.turbineEnergyCapacity == 1,
    "turbine getters were repeated in one tick")
```

Also assert the first constructor sample is populated by initializing `lastUpdatedTick=-1` before its initial `update(0)`.

- [ ] **Step 2: Run the sampling test and verify duplicate/empty sampling fails**

Run: `lua test/device_sampling.lua`

Expected: FAIL because reactor energy stats are fetched through separate closures/internal buffer wrappers and constructors skip tick zero.

- [ ] **Step 3: Refactor cached samples**

In `Reactor:update`, call `self.getEnergyStats()` once and populate all three fields:

```lua
local energy = self.getEnergyStats()
self.lastRFT = energy.energyProducedLastTick or 0
self.energyStored = energy.energyStored or 0
self.energyCapacity = energy.energyCapacity or 0
```

Bind `getEnergyStats = extremeReactor.getEnergyStats`, remove `getLastRFT`, and initialize all class-instance `lastUpdatedTick` fields to `-1`. Keep turbine getters once each because ATM10 exposes them separately. Calculate `rfPerSteam` only from steady, coil-engaged samples with positive flow; do not learn from flywheel deceleration, SCRAM, governor braking, startup grace, topology changes, calibration, or storage-full throttling.

Use `maxRFPerTick`, `maxSteamPerTick`, and `capacityLearning=false` entity overrides before learned values. Use a calibrated reactor curve peak as the initial known capacity when present. Otherwise seed capacity from observed output with a minimum of `1` and expand it only after meeting a target.

- [ ] **Step 4: Run the focused test and simulator**

Run: `lua test/device_sampling.lua && lua test/sim.lua`

Expected: all call-count assertions and existing simulator checks pass.

- [ ] **Step 5: Commit cached sampling**

```bash
git add src/classes/reactor.lua src/classes/turbine.lua src/classes/energybuffer.lua test/device_sampling.lua
git commit -m "refactor: cache one device sample per tick"
```

### Task 4: Explicit per-reactor RF and steam targets

**Files:**
- Modify: `src/classes/reactor.lua:197-311`
- Create: `test/reactor_control.lua`

**Interfaces:**
- Changes `reactor:updateRods()` to `reactor:updateRods(target)`.
- Consumes target `{ unit="rf"|"steam", target=number }`.
- Produces `reactor.dispatchTarget`, `reactor.controlStatus`, and a protected setter result `(ok, error)`.

- [ ] **Step 1: Write failing real-actuator tests**

Construct a passive reactor at 80% insertion and a steam reactor at 80% insertion using complete Modernized API fakes. After sampling, call:

```lua
local ok = passive:updateRods({ unit="rf", target=60000 })
assert(ok and rodAverage(passivePeripheral.rods) < 80,
    "positive per-device RF target did not withdraw rods")

local steamOK = active:updateRods({ unit="steam", target=12000 })
assert(steamOK and rodAverage(activePeripheral.rods) < 80,
    "per-device steam target did not withdraw rods")

local before = rodAverage(passivePeripheral.rods)
assert(passive:updateRods(nil) == false and rodAverage(passivePeripheral.rods) == before,
    "missing dispatch target changed reactor output")
```

Run enough zero-target steps to assert rods move toward 100, and assert `rodWriteThreshold` still suppresses sub-threshold changes.

- [ ] **Step 2: Run the reactor control test and verify the old signature fails**

Run: `lua test/reactor_control.lua`

Expected: FAIL because `updateRods` ignores the explicit target argument.

- [ ] **Step 3: Replace aggregate/equal-share control input with the explicit target**

Keep the existing PID, calibration ownership, efficiency calibration data, rod fractionalization,
steam pressure relief, edge writes, and deadband. Remove `rfLostPerReactor`,
`steamConsumedPerReactor`, and aggregate buffer blending from the output-mode actuator path because
storage correction is already encoded in dispatch. Use:

```lua
local current = self.activelyCooled and self.averageSteamProductionRate or self.averageLastRFT
if not target or target.unit ~= (self.activelyCooled and "steam" or "rf") then
    self.controlStatus = "NO_TARGET"
    return false, "missing or incompatible dispatch target"
end
self.dispatchTarget = target.target
local rodLevel = iteratePID(self.pid, target.target - current)
```

Wrap `self.setRodLevels` with `pcall`; on failure set `controlStatus="WRITE_FAILED"` and return
`false, error`. On success set `controlStatus="TRACKING"` and return `true`.

- [ ] **Step 4: Run focused, calibration, and simulator checks**

Run: `lua test/reactor_control.lua && lua test/sim.lua`

Expected: explicit target checks and all existing calibration/SCRAM checks pass.

- [ ] **Step 5: Commit reactor target control**

```bash
git add src/classes/reactor.lua test/reactor_control.lua test/sim.lua
git commit -m "feat: steer reactors from individual targets"
```

### Task 5: Target-driven turbines with finite sustained overspeed

**Files:**
- Modify: `src/classes/turbine.lua:9-239`
- Create: `test/turbine_dispatch.lua`

**Interfaces:**
- Changes `turbine:updateControl(config, steer)` to `turbine:updateControl(config, steer, target, context)`.
- Consumes target `{ rfTarget, flowTarget, rpmLimit }` and context `{ transient, probeAllowed, storageFull }`.
- Produces `dispatchTarget`, `controlStatus`, `bestSustainedRPM`, and bounded RPM-bin observations.

- [ ] **Step 1: Write failing target and absolute-limit tests**

Use a real `Turbine` around a complete fake peripheral and assert:

```lua
turbine.active, turbine.rpm, turbine.averageRPM = true, 1800, 1800
turbine:updateControl(cfg, true, { rfTarget=5000, flowTarget=1500, rpmLimit=2400 }, {})
assert(fake.coils == true and fake.flowCap > 0, "positive RF target did not engage generation")

turbine:updateControl(cfg, true, { rfTarget=0, flowTarget=0, rpmLimit=2400 }, { storageFull=true })
assert(fake.coils == false and fake.flowCap == 0, "full storage did not stop intentional generation")

turbine.rpm, turbine.averageRPM = 2401, 2401
turbine:updateControl(cfg, false, { rfTarget=5000, flowTarget=2000, rpmLimit=2400 }, {})
assert(fake.coils == true and fake.flowCap == 0, "absolute sustained RPM limit did not govern")
```

Add a transient braking sample followed by a steady sample and assert only the steady sample updates
the RPM-bin capacity profile.

- [ ] **Step 2: Run the turbine dispatch test and verify it fails**

Run: `lua test/turbine_dispatch.lua`

Expected: FAIL because turbine demand comes from its own buffer hysteresis and sustained RPM profiles do not exist.

- [ ] **Step 3: Implement target-driven generation**

Run the safety governor first on every tick. Resolve the absolute limit from the entity override,
target, or `sustainedOverspeedLimitRPM`, and clamp it to a finite number. For a zero RF target,
disengage coils and write zero steam instead of consuming steam to maintain an idle flywheel. For a
positive target, engage coils and use the dispatcher flow target as feed-forward plus the existing
RPM PI correction:

```lua
local desiredFlow = clamp(target.flowTarget or 0, 0, self.flowMaxMax)
local targetRPM = math.min(self.bestSustainedRPM or rpmMin, absoluteLimit - 10)
local rpmError = rpmBandError(avgRpm, targetRPM, targetRPM)
self.pid.integral = clamp(self.pid.integral + config.turbineKi * rpmError, 0, self.flowMaxMax)
self:writeSteam(clamp(desiredFlow + config.turbineKp * rpmError, 0, self.flowMaxMax))
```

Maintain 100-RPM observation bins only for steady coil-engaged samples. When `probeAllowed` is true,
storage is below its target, output is saturated, and sustained overspeed is enabled, advance one
100-RPM bin at a time up to the finite limit. Stop probing after two settled bins fail to beat the
best continuous RF/t. Never count flywheel deceleration, governor braking, or a storage-full period.

Keep existing `writeSteam` and `writeCoils` deadbands and return protected write failures to the controller.

- [ ] **Step 4: Run focused and legacy governor tests**

Run: `lua test/turbine_dispatch.lua && lua test/sim.lua`

Expected: target, storage-full, and finite-limit assertions pass; legacy SCRAM/governor checks remain green.

- [ ] **Step 5: Commit turbine dispatch control**

```bash
git add src/classes/turbine.lua test/turbine_dispatch.lua test/sim.lua
git commit -m "feat: steer turbines from sustained output targets"
```

### Task 6: Controller integration, topology baselines, and failure isolation

**Files:**
- Modify: `src/scripts/controller.lua:26-122,369-429,456-565,574-684`
- Modify: `test/sim.lua:14-35,38-225,241-805`

**Interfaces:**
- Consumes `StorageCoordinator`, `Dispatcher`, cached reactor/turbine fields, and external `EnergyBuffer` samples.
- Produces `_G.overallStats.storage`, `_G.overallStats.dispatch`, `_G.overallStats.reactorTargets`, `_G.overallStats.turbineTargets`, and monotonically increasing `topologyRevision`.
- `runLoop` applies safety, dispatches, isolates write failures, and immediately redistributes failed capacity.

- [ ] **Step 1: Add failing asymmetric integration phases**

Extend the real simulator world with:

```lua
local reactorSmall = makeFakeReactor("reactor_small", { maxRF=20000, rodCount=4 })
local reactorLarge = makeFakeReactor("reactor_large", { maxRF=80000, rodCount=9 })
local externalStore = { stored=1000000, capacity=10000000 }
peripheral.register("storage_0", "energy_storage", {
    getEnergy=function() return externalStore.stored end,
    getEnergyCapacity=function() return externalStore.capacity end,
})
```

Add measured phase assertions, using a 10% convergence tolerance after settling:

- low storage/high demand reaches at least 90% of total sustainable capacity;
- the 20k and 80k reactors settle near equal utilization rather than equal RF/t;
- nearly full storage converges to external draw without positive long-term storage delta;
- full storage/low demand sends zero targets to unnecessary devices;
- a load step raises requested generation before fill drops below 50%;
- attaching or detaching storage resets delta to zero for one tick;
- one reactor setter throwing does not prevent the remaining reactor target from increasing in that tick;
- separate steam groups never exchange flow targets.

- [ ] **Step 2: Run the simulator and verify the new phases fail**

Run: `lua test/sim.lua`

Expected: FAIL on capacity-weighted dispatch, storage throttling, or failure-isolation assertions.

- [ ] **Step 3: Integrate snapshots and target application**

Stop registering reactor and turbine internal batteries as separate `EnergyBuffer` objects. Build
storage sources from cached reactor/turbine fields plus external `energyBuffers`, excluding invalid
and configured IDs. Increment `topologyRevision` on every power-device attach/detach.

Replace `updateOverallStats`' equal-share fields with:

```lua
local storage = storageCoordinator:update({
    sources = storageSources,
    actualGeneration = s.totalRFT,
    availableGeneration = availableRF,
    topologyRevision = topologyRevision,
}, CONTROL_CONFIG)
local dispatch = Dispatcher.allocate(buildDispatchInput(storage), CONTROL_CONFIG)
s.storage, s.dispatch = storage, dispatch
s.reactorTargets, s.turbineTargets = dispatch.reactors, dispatch.turbines
```

Pass `reactorTargets[id]` and `turbineTargets[id]` to each actuator. Wrap each device call
individually with `xpcall`. If a write fails, mark that ID unavailable, raise an alarm, recompute
dispatch once, and apply redistributed targets only to healthy devices. Do not recursively retry
the failed device in the same tick.

Choose at most one turbine for `probeAllowed` per tick and rotate probes by peripheral ID so
overspeed learning cannot destabilize every turbine simultaneously.

- [ ] **Step 4: Run the complete local control suite**

Run: `lua test/storage.lua && lua test/dispatcher.lua && lua test/device_sampling.lua && lua test/reactor_control.lua && lua test/turbine_dispatch.lua && lua test/sim.lua`

Expected: every script exits zero and prints no failed checks.

- [ ] **Step 5: Commit controller integration**

```bash
git add src/scripts/controller.lua test/sim.lua
git commit -m "feat: coordinate storage-aware device dispatch"
```

### Task 7: ATM10 capability report and degraded fallback

**Files:**
- Modify: `src/services/capability.lua:1-36`
- Modify: `src/services/safety.lua`
- Create: `test/capability.lua`

**Interfaces:**
- Changes `CapabilityValidator.validate(id, kind)` to return `ok, missingRequired, report`.
- Report fields: `id`, `peripheralType`, `kind`, `mode` (`control`, `monitor-only`, or `rejected`), `required`, `optional`, `missingRequired`, and `missingOptional`.
- Safety consumes storage trust and per-device degraded states without letting advisory failures clear or bypass SCRAM.

- [ ] **Step 1: Write failing ATM10 capability tests**

Register a complete Modernized API reactor and turbine, an object missing `setFluidFlowRateMax`, and
an object with only the historical `getBladeEffiency` spelling. Assert complete objects are
`control`, the missing actuator is `monitor-only` or `rejected` and receives no writes, and either
blade-efficiency spelling is reported as supported optional telemetry.

Also assert `CapabilityValidator.reports()` retains the peripheral type and exact missing method
lists after multiple validations.

- [ ] **Step 2: Run the capability test and verify report-shape failure**

Run: `lua test/capability.lua`

Expected: FAIL because current reports omit peripheral type, optional methods, and operating mode.

- [ ] **Step 3: Split required sampling, required actuation, and optional methods**

Use explicit method groups. A device missing a sampling method is `rejected`; a device that can be
sampled but cannot be safely actuated is `monitor-only`; only complete devices are `control` and
enter dispatch. Feature-detect `getBladeEfficiency`/`getBladeEffiency` as alternatives.

If external storage disappears, reset the topology baseline, raise an advisory alarm, and use valid
internal buffers. If no trustworthy storage remains, set reserve correction to zero and follow the
conservative demand estimate. Do not transition out of SCRAM or weaken missing-turbine interlocks.

- [ ] **Step 4: Run capability, safety, and simulator tests**

Run: `lua test/capability.lua && lua test/sim.lua && lua test/watchdog.lua`

Expected: all scripts exit zero.

- [ ] **Step 5: Commit compatibility handling**

```bash
git add src/services/capability.lua src/services/safety.lua test/capability.lua
git commit -m "feat: validate ATM10 device control capabilities"
```

### Task 8: Operator visibility

**Files:**
- Modify: `src/classes/monitor.lua:109-259,260-318`
- Modify: `test/sim.lua`

**Interfaces:**
- Consumes `overallStats.storage`, `overallStats.dispatch`, and per-device `dispatchTarget`, capacity, utilization, and control status.
- Produces visible aggregate demand/capacity/storage lines and per-device target-versus-actual card rows without changing remote frame transport.

- [ ] **Step 1: Add failing monitor behavior assertions**

Render overview, reactor, and turbine roles to the real terminal stub. Assert the rendered text
contains labels `Demand`, `Requested`, `Available`, `Stored`, `Charge`, `Target`, and `Actual`, and
that a degraded device card contains `DEGRADED`. Assert small monitors still render through `pcall`
without out-of-bounds errors.

- [ ] **Step 2: Run the simulator and verify missing telemetry fails**

Run: `lua test/sim.lua`

Expected: FAIL because current monitor cards do not show storage-aware dispatch values.

- [ ] **Step 3: Render aggregate and per-device dispatch state**

Add compact header rows for external demand, required/available RF/t, stored RF/capacity, fill
percentage, and signed charge rate. Add target, actual, utilization, capacity source
(`configured`, `learned`, or `observing`), and status to reactor/turbine cards. List contributing
storage IDs in the detail view so operators can diagnose double counting.

Keep all drawing through the existing buffered terminal path; do not change remote protocol or use
`window.create` on remote displays.

- [ ] **Step 4: Run UI and remote-display suites**

Run: `lua test/sim.lua && lua test/remote_server.lua && lua test/remote_client.lua`

Expected: monitor checks and remote full/delta frame tests pass.

- [ ] **Step 5: Commit monitor telemetry**

```bash
git add src/classes/monitor.lua test/sim.lua
git commit -m "feat: display storage-aware dispatch telemetry"
```

### Task 9: ATM10 7.2 documentation and final verification

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `V2-OPERATIONS.md`
- Modify: `docs/planned-features.md`

**Interfaces:**
- Documents all new config keys and per-entity overrides.
- Documents ATM10 7.2/Minecraft 1.21.1 compatibility, sustained output versus flywheel burst behavior, storage exclusions, monitor telemetry, and commissioning.

- [ ] **Step 1: Update operator documentation**

Document this commissioning sequence:

1. Start with `sustainedOverspeedEnabled=false` and verify all device capability reports.
2. Confirm the monitor lists each physical storage pool exactly once; add duplicate IDs to
   `storageExclusions`.
3. Apply a load above installed generation and confirm every device reaches at least 90% of its
   configured or learned sustainable capacity.
4. Reduce load and confirm storage charges through 50-85%, then generation converges on demand.
5. Test detach/failure redistribution before enabling unattended operation.
6. Enable sustained overspeed only after setting a finite per-turbine RPM limit and observing each
   turbine during its probe.

Include examples for `maxRFPerTick`, `maxSteamPerTick`, `maxFlowPerTick`, `dispatchWeight`,
`capacityLearning`, `sustainedOverspeedLimitRPM`, and `storageExclusions`. Keep wget installation as
the primary deployment path.

- [ ] **Step 2: Run syntax checks for every shipped Lua file**

Run:

```bash
lua -e "for p in io.popen('git ls-files \"*.lua\"'):lines() do assert(loadfile(p), p) end"
```

Expected: exit zero with no syntax errors.

- [ ] **Step 3: Run the entire test suite fresh**

Run:

```bash
lua test/storage.lua
lua test/dispatcher.lua
lua test/device_sampling.lua
lua test/reactor_control.lua
lua test/turbine_dispatch.lua
lua test/capability.lua
lua test/sim.lua
lua test/remote_server.lua
lua test/remote_client.lua
lua test/watchdog.lua
```

Expected: every command exits zero, all simulator checks print `PASS`, and no warnings or failures appear.

- [ ] **Step 4: Review requirements against the approved spec**

Confirm every success criterion in `docs/superpowers/specs/2026-09-01-sustained-output-dispatch-design.md` has a passing test or an explicit ATM10 commissioning step. Confirm `git diff --check` exits zero and `git status --short` contains only intended files.

- [ ] **Step 5: Commit documentation and verification updates**

```bash
git add README.md docs/architecture.md V2-OPERATIONS.md docs/planned-features.md
git commit -m "docs: add sustained output commissioning guide"
```
