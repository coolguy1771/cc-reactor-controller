# Task 8 report: operator visibility

## RED

Added real terminal-stub assertions to `test/sim.lua` for overview, reactor, and
turbine roles, plus a degraded card and a 20x10 monitor `pcall`. Before the UI
change, the focused simulator run reported 19 failures: the aggregate labels
`Demand`, `Requested`, `Available`, `Stored`, `Charge`, and `Actual` were absent,
and `DEGRADED` was absent. The small monitor assertion already passed.

## GREEN

`src/classes/monitor.lua` now renders storage-aware aggregate demand, requested
and available generation, stored/capacity, fill, and signed charge. Device cards
render target/actual, utilization, capacity source (`configured`, `learned`, or
`observing`), and control status, including `DEGRADED`. Detail pages list
contributing storage source IDs. Drawing remains on the existing buffered
terminal path; remote transport was not changed. Capacity-source probing is
guarded with `pcall` for monitor safety.

## Verification

All commands completed successfully with the portable Lua 5.4 runtime:

```
.superpowers/tools/lua54/lua54.exe test/sim.lua
.superpowers/tools/lua54/lua54.exe test/remote_server.lua
.superpowers/tools/lua54/lua54.exe test/remote_client.lua
git diff --check
```

The simulator ended with `ALL CHECKS PASSED`, and the remote suites ended with
`REMOTE DISPLAY CHECKS PASSED` and `REMOTE CLIENT CHECKS PASSED`.

## Fix Round 1

### RED

Added sentinel-value assertions for aggregate values, device target/actual and
numeric utilization, all capacity-source variants, and a contributing storage ID.
The first run failed on device numeric rendering, utilization/source variants,
and detail storage ID. This also exposed that the active-reactor source lookup
needed its `maxSteamPerTick` key.

### GREEN

Capacity-source detection now uses `maxSteamPerTick` for actively cooled reactors
and `maxRFPerTick` for passive reactors and turbines. Target and actual values are
rendered on separate compact card rows so both remain visible on narrow cards.
Sentinel tests now pass, including active configured source coverage and numeric
aggregate/device values.

Final verification again passed `test/sim.lua`, plus both remote suites and
`git diff --check`; the worktree is clean.

## Fix Round 2

### RED

Added a real terminal-stub assertion using distinct sentinel fuel (`7.321`) and
waste (`987`) values. The focused simulator failed because the two existing
draws shared `iy + 10`, so Waste overwrote Fuel.

### GREEN

Fuel and Waste now render together on one compact, non-overlapping card row,
which preserves both values within the fixed card height and remains safe for
small monitors. Simulator, remote server/client, and `git diff --check` all pass.
