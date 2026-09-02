## Task 4 report

Implemented explicit per-reactor RF/steam target control.

RED: `.superpowers/tools/lua54/lua54.exe test/reactor_control.lua` failed at line 35 because `updateRods` ignored explicit targets.

GREEN: focused test exited 0 and printed `reactor control: ok`; `git diff --check` exited 0.

The simulator was run and reports legacy output-mode failures because controller target integration is owned by Task 6.

Fix Round 1 RED: regression assertions were added for threshold status and protected actuator failure; pre-fix behavior did not satisfy the contract.

Fix Round 1 GREEN: `lua test/reactor_control.lua` and `lua test/device_sampling.lua` both exited 0; `git diff --check` exited 0 (only CRLF normalization warnings).

Fix Round 2 RED: focused test failed at line 53 with `rod write threshold did not suppress small change`; diagnosis showed the setup produced an edge (0%) PID result, which correctly bypasses threshold suppression.

Fix Round 2 GREEN: after setting a non-edge prior rod level and measured output yielding a sub-threshold delta, `.superpowers/tools/lua54/lua54.exe test/reactor_control.lua` printed `reactor control: ok` and exited 0; `test/device_sampling.lua` printed `device sampling ok` and exited 0; `git diff --check` exited 0.

Fix commits: `b2c6b603fd11269aa7d1a57fff7d7cd4c54dbec0`, `4cff6523564c0da520f8f9c474ae026c2732248a`
