# Task 5 RED/GREEN report

## RED

The initial `lua test/turbine_dispatch.lua` invocation could not run because `lua` was not on PATH; this is recorded honestly and is not claimed as behavioral RED evidence.

## GREEN

With `.superpowers/tools/lua54/lua54.exe`, `test/turbine_dispatch.lua`, `test/device_sampling.lua`, and `test/reactor_control.lua` all passed. `test/sim.lua` ran and reported exactly 16 legacy integration failures caused by pending Task 6 controller target/context calls; governor and safety assertions remained passing.

Implemented finite absolute RPM precedence (entity override > target > config), zero-target shutdown, feed-forward + PI, bounded 100-RPM steady observations, and gated one-bin probing that stops after two settled non-improving bins while excluding transient/braking/storage-full samples.

## Fix Round 1 evidence

Behavioral regression RED command (before fixes):

    .superpowers/tools/lua54/lua54.exe test/turbine_dispatch.lua

The initial dispatch assertions passed, but the added probing/write-failure regression assertions exposed missing probe steering/settling and unprotected write behavior. This was corrected in commits `20109b8` and `ca9b59c`.

GREEN command/output:

    .superpowers/tools/lua54/lua54.exe test/turbine_dispatch.lua
    turbine dispatch ok
    .superpowers/tools/lua54/lua54.exe test/device_sampling.lua
    device sampling ok
    .superpowers/tools/lua54/lua54.exe test/reactor_control.lua
    reactor control: ok

The portable simulator was rerun after the fixes. `test/sim.lua` reports exactly 16 failures, all legacy controller integration assertions requiring Task 6 to pass dispatch targets/context; safety governor and ceiling checks remain passing. `git diff --check` passes. Fix commits: `20109b8`, `ca9b59c`.

## Fix Round 2 verification

Commands and exact focused outputs:

    .superpowers/tools/lua54/lua54.exe test/turbine_dispatch.lua
    turbine dispatch ok
    .superpowers/tools/lua54/lua54.exe test/device_sampling.lua
    device sampling ok
    .superpowers/tools/lua54/lua54.exe test/reactor_control.lua
    threshold true TRACKING 11 11
    reactor control: ok
    git diff --check

The portable simulator still reports 16 failures, classified as Task 6 controller integration (missing target/context wiring); no new Task 5-specific simulator failure was introduced. Review of `test/turbine_dispatch.lua` confirms the current file covers positive/zero target and absolute-limit behavior, but does not yet contain every requested Round 2 regression case (transient/steady bin filtering, probe progression/settling, finite precedence matrix, and explicit write-failure/constructor assertions). Commits for the Round 2 source fixes are `92f0358` and `bba5037`.
Round 2 final verification after `2927699`: turbine dispatch and regressions both pass; device sampling and reactor control pass; simulator remains exactly 16 Task 6-only integration failures; `git diff --check` passes. Coverage now includes transient/steady bins, bounded probing, and protected write failures. Round 2 commits: `92f0358`, `bba5037`, `87aa2e4`, `4021e46`, `e585a1e`, `0582daa`, `2927699`.
Round 3 final verification after `86b5a73`: portable turbine dispatch, regression, finite/failure, and branch matrix outputs all pass; device sampling and reactor control pass; `git diff --check` passes. Simulator remains exactly 16 legacy Task 6 controller-integration failures. Round 3 commits: `98de3c2`, `c55cc91`, `1779e237`, `fb4fcbf`, `4194360`, `e4b9ca3`, `8d9f2cb`, `86b5a73`. Coverage includes exact probe-bin settling/stop assertions, finite fallback/precedence, constructor failures, and branch-level write-failure propagation.
