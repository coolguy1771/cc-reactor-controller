# Reactor Controller v2 operations

## Commissioning sequence

1. Finish and manually verify every reactor, turbine, coolant loop, water return, and power tap.
2. Install the controller while reactors contain no fuel or are otherwise physically inhibited.
3. Run `setup` on the reactor computer. It records discovered equipment as expected peripherals.
4. Reboot. Confirm the computer reaches `READY`; it deliberately remains `OFF`.
5. Install/configure remote displays and the independent watchdog.
6. Test SCRAM with the reactor unfueled. Confirm the watchdog's asserted redstone signal produces
   the intended hardware shutdown.
7. Add fuel and press Auto/Reactors On to enter `AUTO_OUTPUT`.

## Operating states

| State | Reactor behavior | Reset/start behavior |
| --- | --- | --- |
| `BOOTING` / `SELF_TEST` | Off, rods inserted | Automatic self-test only |
| `READY` / `OFF` | Off, rods inserted | Operator may start after a passing self-test |
| `RUNNING` | Selected automatic/manual mode | Operator may stop |
| `MAINTENANCE` | Off, rods inserted | Deliberate maintenance state |
| `DEGRADED` | Off | Fix capability/peripheral errors |
| `SCRAM` | Reactor off, rods 100%, steam 0, coils braking | Latched; reset only after checks pass |

## Remote permissions

Remote clients not listed in `remoteClients` receive the `remoteDefaultRole` (`read-only`). Grant
touchscreen control explicitly:

```lua
remoteClients = {
  [42] = "control",
  [57] = "read-only",
}
```

Remote flywheel activation is disabled by default. Local activation requires two touches within
five seconds. The global overspeed SCRAM still takes precedence over flywheel operation.

## Display roles

Assign individual local or remote peripheral IDs to views:

```lua
displayRoles = {
  ["monitor_0"] = "overview",
  ["remote:42:monitor_1"] = "alarms",
  ["remote:42:monitor_2"] = "history",
}
```

The Change View button cycles through `overview`, `reactors`, `turbines`, `alarms`, and `history`.
Touch an equipment card to open its detail page; touch the detail page to return.

## Optional telemetry

```lua
telemetryEnabled = true,
telemetryUrl = "https://collector.example.invalid/reactor",
telemetryIntervalSeconds = 5,
telemetryAuthHeader = "Bearer replace-me",
```

The exporter sends aggregate grid/steam state plus each reactor and turbine as JSON. HTTP failures
raise an advisory alarm without affecting local control.

## Tests

With Lua 5.3/5.4 or `texlua` available in the repository root:

```text
lua test/sim.lua
lua test/remote_server.lua
lua test/remote_client.lua
lua test/watchdog.lua
```

The suite covers normal load phases, PID behavior, turbine governor behavior, calibration,
efficiency dispatch, safe startup, temperature and missing-turbine SCRAMs, API rejection, alarm and
history views, remote full/delta frames, session/sequence replay rejection, client rendering, and
watchdog fail-safe clearing.
