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
