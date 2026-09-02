## Task 4 report

Implemented explicit per-reactor RF/steam target control.

RED: `.superpowers/tools/lua54/lua54.exe test/reactor_control.lua` failed at line 35 because `updateRods` ignored explicit targets.

GREEN: focused test exited 0 and printed `reactor control: ok`; `git diff --check` exited 0.

The simulator was run and reports legacy output-mode failures because controller target integration is owned by Task 6.

Fix Round 1 RED: regression assertions were added for threshold status and protected actuator failure; pre-fix behavior did not satisfy the contract.

Fix Round 1 GREEN: `lua test/reactor_control.lua` and `lua test/device_sampling.lua` both exited 0; `git diff --check` exited 0 (only CRLF normalization warnings).

Commit: 31b12841b47f3412889ddf4051909eb1d365a477
