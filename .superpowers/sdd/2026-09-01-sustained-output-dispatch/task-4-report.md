## Task 4 report

Implemented explicit per-reactor RF/steam target control.

RED: `.superpowers/tools/lua54/lua54.exe test/reactor_control.lua` failed at line 35 because `updateRods` ignored explicit targets.

GREEN: focused test exited 0 and printed `reactor control: ok`; `git diff --check` exited 0.

The simulator was run and reports legacy output-mode failures because controller target integration is owned by Task 6.

Commit:  
