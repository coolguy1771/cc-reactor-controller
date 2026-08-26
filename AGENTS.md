## Learned User Preferences

- Prefer wget-based in-game setup via `install.lua` (controller, display, watchdog roles); do not add or recommend zip packaging.
- GitHub username is `coolguy1771`; repo is `coolguy1771/cc-reactor-controller` on branch `main`.
- `install.lua` defaults should use `coolguy1771` / `cc-reactor-controller` / `main` so in-game commands can omit extra args.

## Learned Workspace Facts

- ComputerCraft reactor controller for Extreme Reactors 2, used in ATM10 modpack.
- Three deployable roles: controller (reactor computer), display (remote monitor), watchdog (optional redstone safety).
- In-game install: `wget run https://raw.githubusercontent.com/coolguy1771/cc-reactor-controller/main/install.lua <role>`.
- Remote display and watchdog share one secret with the controller (`remoteSecret` / `secret` in respective config files).
- Display computers need `"control"` in controller `remoteClients` for touchscreen buttons; unlisted clients are read-only.
- Remote Ender Modem displays must not use `window.create`; draw directly to the buffered terminal proxy.
- Remote monitor touches can double-fire over Rednet; debounce duplicate coordinates within 500ms on client and server.
- Controller defaults to auto mode after self-test (`requireManualStart = false`); boots into AUTO_OUTPUT unless overridden.
