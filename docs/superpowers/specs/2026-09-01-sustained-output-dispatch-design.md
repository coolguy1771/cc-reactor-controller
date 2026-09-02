# Sustained Output Dispatch Design

## Purpose

Upgrade the Extreme Reactors controller for All the Mods 10 version 7.2 so it controls every
connected reactor, turbine, and power-storage peripheral independently. The controller must
maximize sustained RF/t when demand and storage headroom permit, then throttle generation to
measured demand as storage fills. Fuel economy is not the optimization objective.

The deployment target is Minecraft 1.21.1 on NeoForge, using ATM10 7.2's Extreme Reactors and
CC:Tweaked builds. Runtime peripheral capability checks are authoritative; the controller must not
accept an object merely because its peripheral type matches an older Big Reactors API.

## Success Criteria

- At low storage or under demand at least equal to installed capacity, every usable generator is
  assigned a sustainable target up to its learned or configured capacity.
- At lower demand, total generation converges on external demand plus a bounded storage-recharge
  correction.
- The recharge correction tapers to zero through the configured storage target band, and the
  controller does not intentionally overproduce when storage is full.
- Unequal reactors and turbines receive targets based on their own usable capacity instead of an
  equal share.
- Active reactors and turbines coordinate only within their configured steam group.
- A device attachment, detachment, invalid sample, or failed write cannot prevent healthy devices
  from being controlled during the same cycle.
- Peripheral getters are sampled once per control tick, and insignificant setter changes remain
  suppressed by write thresholds.
- Existing safety interlocks remain higher priority than output optimization.
- Existing configurations remain valid; new behavior is enabled through defaults and optional
  per-entity overrides.

## Control Model

### Immutable tick snapshot

At the beginning of each tick, the controller reads each connected peripheral once and builds a
snapshot containing:

- total stored RF and total usable storage capacity;
- aggregate fill percentage and tick-to-tick charge/discharge rate;
- actual passive-reactor and turbine generation;
- estimated external grid demand;
- each reactor's actual output, active state, temperatures, rod level, cooling mode, and capacity
  estimate;
- each turbine's actual RF/t, steam flow, flow limit, RPM, coil state, internal storage, and
  capacity estimate;
- each steam group's stored steam, capacity, production, consumption, and available equipment.

The snapshot is immutable for the rest of the tick. Dispatch and monitoring consume the same
values, preventing repeated peripheral calls and internally inconsistent calculations.

Internal reactor and turbine buffers are included once. If a generic energy-storage peripheral
represents the same physical buffer, an explicit entity override can exclude it from aggregate
storage. The monitor exposes the contributing storage IDs so operators can identify accidental
double counting.

### Demand estimate

External demand is derived from conservation of energy over a tick:

```text
externalDemand = max(0, actualGeneration - storageDelta)
```

where `storageDelta` is positive while total stored RF rises. The result is smoothed over a short
window and clamped against invalid jumps caused by device attachment or detachment. The first
sample after the storage topology changes establishes a new baseline and is not used as demand.

Required generation is:

```text
requiredGeneration = externalDemand + rechargeCorrection
```

Below `storageTargetMin`, the recharge correction requests available surplus generation. Between
`storageTargetMin` and `storageTargetMax`, it tapers continuously toward zero. At or above
`storageTargetMax`, it is zero. At the hard-full threshold, generation targets are immediately
recomputed without waiting for the normal steering interval.

### Per-device dispatch

The dispatcher receives the tick snapshot and produces explicit target tables keyed by peripheral
ID. It does not call peripherals.

Passive reactors receive RF/t targets. Active reactors receive steam/t targets for their own steam
group. Turbines receive RF/t and steam-flow targets. Allocation is proportional to each device's
usable sustainable capacity, with configured capacity and dispatch-weight overrides taking
precedence over learned values.

If required generation is at least installed capacity, all usable devices receive their maximum
sustainable target. If demand is lower, devices share the target proportionally so unequal devices
run at comparable utilization. This avoids overloading small devices and underusing large ones.

Within a steam group, turbine electrical targets are translated into flow targets using recent
RF-per-steam observations. The group's active reactors are then assigned enough total steam
production to satisfy those turbine targets and correct the steam-buffer level. No group borrows
capacity or measurements from another group.

### Capacity learning

Each device maintains an exponentially weighted estimate of sustainable capacity from valid,
steady-state samples. Learning is suspended during startup grace periods, SCRAM, calibration,
topology changes, storage-full throttling, or when the device is not being asked to approach its
current limit. A device that repeatedly misses its target has its usable estimate reduced; a
device that meets its limit may increase its estimate gradually up to the API-reported or
configured ceiling.

New devices enter observation mode before receiving a ramped target. A configured per-entity
capacity disables learning for that capacity and is used as the authoritative ceiling.

### Sustained turbine operation and overspeed

Maximum sustained RF/t is distinct from flywheel burst energy. Turbines normally run with coils
engaged at the best observed continuous operating point. Rotor energy released during deceleration
is excluded from sustainable-capacity learning.

Sustained overspeed may be enabled because the operator accepts the risk, but learning is always
bounded by a configurable absolute RPM limit. A zero or missing limit uses a finite conservative
discovery ceiling rather than infinity. Overspeed is used only when steady-state samples show a
higher continuous RF/t than the normal band. The existing flywheel mode remains a separate burst
feature and is not counted as sustained capacity.

## Components

### `src/services/storage.lua`

Own storage aggregation, topology baselines, fill percentage, storage delta, external-demand
estimation, and recharge correction. It consumes already-read device samples and performs no
peripheral I/O.

### `src/services/dispatcher.lua`

Own pure target allocation, proportional utilization, steam-group electrical-to-flow conversion,
and capacity-weighted redistribution after failures. It returns per-ID reactor and turbine target
tables plus aggregate requested/available capacity.

### `src/scripts/controller.lua`

Orchestrate sampling, snapshot creation, safety evaluation, dispatch, device control, monitor
updates, and hot-plug topology resets. Per-device control calls are isolated with protected calls
so one failure does not abort the pass.

### `src/classes/reactor.lua`

Expose one cached sample per tick and accept an explicit RF/t or steam/t target. The existing rod
PID remains the actuator, but its error comes from the device target instead of an aggregate equal
share. Calibration and efficiency-mode data remain readable, but output mode is governed by the
sustained-output dispatcher.

### `src/classes/turbine.lua`

Expose one cached sample per tick, maintain bounded sustainable-capacity observations, and accept
explicit RF/t and flow targets. Safety governor decisions remain first, followed by coil and steam
control. Setter caching and thresholds continue to suppress redundant writes.

### `src/classes/monitor.lua`

Display external demand, required generation, installed/usable capacity, total stored RF,
aggregate fill, charge/discharge rate, and dispatch saturation. Device cards show assigned target,
actual output, utilization, learned/configured capacity, and degraded or observation status.

### Configuration

The default configuration adds:

```lua
storageTargetMin = 50,
storageTargetMax = 85,
storageReserveGain = 0.25,
dispatchRebalanceThreshold = 0.02,
capacityLearningRate = 0.05,
sustainedOverspeedEnabled = true,
sustainedOverspeedLimitRPM = 2400,
storageExclusions = {},
```

Per-entity overrides may set `dispatchWeight`, `maxRFPerTick`, `maxSteamPerTick`,
`maxFlowPerTick`, `sustainedOverspeedLimitRPM`, and `capacityLearning = false`. Existing override
keys, steam groups, responsiveness controls, and safety settings retain their meaning.

## Safety and Degraded Operation

Safety evaluation precedes dispatch. SCRAM, thermal limits, invalid critical readings,
steam-buffer limits, and the absolute RPM limit override optimization targets.

- A missing or invalid device sample removes that device from usable capacity for the tick.
- A failed control write marks only that device degraded and triggers immediate redistribution to
  healthy devices.
- If external storage disappears, the controller falls back to valid internal reactor and turbine
  buffers, raises an alarm, and resets the demand baseline.
- If no trustworthy storage remains, recharge correction is disabled and generation follows the
  conservative demand estimate until storage returns.
- If turbine capacity disappears from an active steam group, reactor steam targets fall to zero
  except for any explicit buffer correction allowed by safety limits.
- Full storage triggers immediate downward dispatch; low storage permits full installed output.
- Hot-plugged devices ramp from observation to their assigned target instead of receiving a sudden
  full-output command.

Optimization never clears a latched SCRAM or weakens the independent watchdog behavior.

## ATM10 7.2 Compatibility

Startup capability validation checks the exact methods used by sampling and actuation. Reactor and
turbine objects are accepted only when the required Modernized API calls exist. Optional methods
are feature-detected, including known spelling variants, and their absence disables only the
dependent metric or optimization.

The capability report records the peripheral type, available required methods, missing optional
methods, and whether the device can be sampled, actuated, or monitored only. Unsupported devices
remain visible as rejected peripherals and are never sent control commands.

## Verification Strategy

The existing headless simulator will be extended with asymmetric reactors and turbines, multiple
external storage devices, explicit call counters, configurable API capabilities, and separate
steam groups. Tests will cover:

1. Low storage plus high demand saturates every usable generator at its sustainable capacity.
2. Mid-band storage tracks demand while applying a bounded recharge correction.
3. Nearly full storage smoothly tapers generation to demand.
4. Full storage under low demand produces no intentional surplus.
5. A sudden load step ramps generation before reserves fall below the lower target.
6. Unequal devices receive proportional targets and converge near equal utilization.
7. Steam production follows only the assigned turbines in each group.
8. Attach, detach, invalid samples, and failed writes rebalance targets without aborting the pass.
9. Storage topology changes do not create a false demand spike.
10. Getter calls occur once per tick and setters respect configured deadbands.
11. Flywheel deceleration is excluded from sustainable-capacity learning.
12. Sustained overspeed remains below the configured finite absolute limit.
13. ATM10-style capability fixtures accept supported Modernized API peripherals and reject
    incomplete or legacy-only objects before actuation.
14. Existing safe startup, SCRAM, remote display, watchdog, calibration, and UI tests remain green.

In-game commissioning on ATM10 7.2 will compare the monitor's requested capacity, actual output,
storage delta, and estimated demand through low-, mid-, and full-storage conditions. Because the
headless physics are approximate, capacity-learning gains and overspeed limits remain configurable
and must be commissioned conservatively before unattended use.

## Documentation and Deployment

README and operations documentation will identify ATM10 7.2/Minecraft 1.21.1 as the compatibility
target, explain storage exclusions and new overrides, distinguish sustained output from flywheel
burst output, and provide a commissioning checklist. The existing transactional `install.lua`
workflow and wget-based role installation remain unchanged.
