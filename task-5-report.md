# Task 5 RED/GREEN report

## RED

Added `test/turbine_dispatch.lua` using a real `Turbine` instance and complete fake peripheral. The mandated command was:

    lua test/turbine_dispatch.lua

It could not be executed in this environment because PowerShell reports `lua` is not recognized (no Lua executable is installed/on PATH).

## GREEN

Implemented target-aware `Turbine:updateControl(config, steer, target, context)` while retaining the legacy path when no target is supplied. The implementation runs the absolute finite sustained-RPM governor before dispatch, supports entity > target > config limit resolution, explicitly disengages coils and writes zero steam for zero RF targets, applies flow feed-forward plus PI correction for positive targets, and records bounded steady 100-RPM observations while excluding transient/braking/storage-full samples.

The focused test and legacy simulation could not be run for the same missing-interpreter reason. `git diff --check` completed without whitespace errors.
