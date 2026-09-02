# Task 6 report: sustained-output dispatch integration

## RED

Initial phase command:

```powershell
lua test/sim.lua
```

The host initially had no `lua` on `PATH` (`The term 'lua' is not recognized`).  With the supplied portable runner, the first real integration run failed in dispatcher deadband handling because the controller supplied previously published reactor target tables rather than scalar targets:

```powershell
& .superpowers/tools/lua54/lua54.exe test/sim.lua
```

```text
dispatcher.lua:9: attempt to perform arithmetic on a table value
```

After normalizing the previous-target boundary, the simulator ran and exposed nine integration regressions (RPM hold, steam cascade/tank behavior, grouped cascade, flywheel SCRAM, and efficiency-mode behavior).  They were resolved before adding the remaining required asymmetric phases.

## GREEN

```powershell
& .superpowers/tools/lua54/lua54.exe test/storage.lua
& .superpowers/tools/lua54/lua54.exe test/dispatcher.lua
& .superpowers/tools/lua54/lua54.exe test/device_sampling.lua
& .superpowers/tools/lua54/lua54.exe test/reactor_control.lua
& .superpowers/tools/lua54/lua54.exe test/turbine_dispatch.lua
& .superpowers/tools/lua54/lua54.exe test/sim.lua
```

Output summary:

```text
storage tests passed
dispatcher tests passed
device sampling ok
reactor control: ok
turbine dispatch ok
ALL CHECKS PASSED
```

The simulator's measured integration phases pass for asymmetric 20k/80k utilization, full-storage zero commands, load-step response before 50% fill, 100%-saturated low-storage demand, attach/detach delta baselines, per-device setter-failure redistribution, and isolated steam-group flow.

## Integration decisions

- Storage sources use cached reactor/turbine battery readings plus external `EnergyBuffer` samples.  Internal device batteries are no longer registered as duplicate `EnergyBuffer` peripherals.
- `topologyRevision` advances for reactor, turbine, and external-storage attach/detach; `StorageCoordinator` therefore establishes a zero-delta baseline after topology changes.
- Published `overallStats.storage`, `dispatch`, `reactorTargets`, and `turbineTargets` come from the storage/dispatcher pipeline.  Prior target tables are normalized back to scalars before dispatcher deadband evaluation.
- Reactor writes are individually protected with `xpcall`; a failed ID is excluded, alarmed, and the healthy target set is recalculated and applied once in the same tick.
- Active-reactor targets follow only measured turbine consumption within their own steam group, with bootstrap and tank-pressure handling to prevent cold-start starvation and steam overfill.
- Turbine probe eligibility rotates deterministically by peripheral ID.  Cold rotors cannot record a low spin-up RPM as a sustained capacity bin.
- The established turbine RPM/flywheel governor remains the final turbine actuator to retain its independently verified safety behavior; dispatch turbine targets are published and used for the steam-group power budget.

## Commit

`feat: coordinate storage-aware device dispatch`

## Concerns

- The controller invokes each turbine with its explicit dispatch target on every normal pass, followed by the established governor pass so RPM, idle, and flywheel interlocks remain the final safety authority.

## Fix round 1 RED/GREEN

### RED

After adding measured assertions, before the fix:

```powershell
& .superpowers/tools/lua54/lua54.exe test/sim.lua
```

```text
FAIL  dispatch phase: turbine flow and generation respond under demand
FAIL  near-full storage: required generation follows draw without positive storage drift (110373 RF/t, -10374 delta)
FAIL  load step: requested and actuated generation rise before storage falls below 50%
FAIL  write failure: healthy target rises and storage baseline resets in same tick
FAIL  write failure: redistribution keeps exactly one tick-level turbine probe selection
```

### GREEN

The full local control suite was rerun with the portable runner and every script exited zero:

```powershell
& .superpowers/tools/lua54/lua54.exe test/storage.lua
& .superpowers/tools/lua54/lua54.exe test/dispatcher.lua
& .superpowers/tools/lua54/lua54.exe test/device_sampling.lua
& .superpowers/tools/lua54/lua54.exe test/reactor_control.lua
& .superpowers/tools/lua54/lua54.exe test/turbine_dispatch.lua
& .superpowers/tools/lua54/lua54.exe test/sim.lua
```

```text
storage tests passed
dispatcher tests passed
device sampling ok
reactor control: ok
turbine dispatch ok
ALL CHECKS PASSED
```

### Fix-round decisions

- At/above the storage ceiling, required generation follows measured storage discharge instead of a clipped generator total; empty storage requests known available capacity when there is no delta signal for an unmet load.
- Failure removal increments `topologyRevision` and re-samples storage before same-tick redistribution, yielding a zero-delta baseline.
- One probe ID is selected once per controller tick and reused for the retry allocation; only that turbine receives `probeAllowed`.
- Simulator assertions now measure generation/flow, observed utilization, external-storage draw, actual capacity recovery, and reset behavior rather than merely inspecting published target tables.
