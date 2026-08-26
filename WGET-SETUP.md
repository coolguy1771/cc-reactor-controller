# WGET setup for ATM10 (ComputerCraft)

Enable HTTP in CC:Tweaked (`http_enabled` in config) and attach a modem to each computer.

Repo: `coolguy1771/cc-reactor-controller` on branch `main`.

## Reactor controller computer

```text
wget run https://raw.githubusercontent.com/coolguy1771/cc-reactor-controller/main/install.lua controller
setup
reboot
```

## Remote display computer

```text
wget run https://raw.githubusercontent.com/coolguy1771/cc-reactor-controller/main/install.lua display
reboot
```

Edit `/remote-display.conf` after first boot to set the shared secret, then reboot again.

## Watchdog computer

```text
wget run https://raw.githubusercontent.com/coolguy1771/cc-reactor-controller/main/install.lua watchdog
reboot
```

Edit `/watchdog.conf` on first boot (secret, redstone side), then reboot.

## Updating

Re-run the same `wget run install.lua ...` command for the role. The installer backs up the
previous files to `/.reactor-update-backup` and rolls back on failure. Use `rollback` to restore
manually.
