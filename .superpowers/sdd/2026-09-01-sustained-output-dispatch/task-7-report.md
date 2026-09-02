# Task 7 report: ATM10 capability and degraded fallback

## RED

The portable Lua 5.4 runtime ran the focused test before the report-order contract
was corrected:

```
C:\...\lua54.exe: test/capability.lua:8: reactor required item 2
stack traceback:
    [C]: in function 'assert'
    test/capability.lua:8: in local 'assertList'
    test/capability.lua:50: in main chunk
```

The failure established that the test expected an obsolete interleaved method list,
while the implementation's explicit contract is deterministic grouped ordering:
all sampling methods first, then all actuation methods.

## GREEN

The test was updated to assert the grouped report contract. It then passed with the
portable runtime. The implementation provides control / monitor-only / rejected
classification, exact structured report fields, both blade-efficiency spellings, and
advisory storage-trust handling that does not change SCRAM behavior.

Fresh verification passed:

```
.superpowers\tools\lua54\lua54.exe test/capability.lua       # capability tests passed
.superpowers\tools\lua54\lua54.exe test/watchdog.lua         # WATCHDOG CHECKS PASSED
.superpowers\tools\lua54\lua54.exe test/sim.lua              # ALL CHECKS PASSED
```

The full relevant Lua suite also passed: capability, device sampling, dispatcher,
reactor control, remote client/server, storage, turbine dispatch, watchdog, and
simulator. `git diff --check` completed without whitespace errors.
