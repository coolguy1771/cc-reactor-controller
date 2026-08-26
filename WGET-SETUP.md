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

Re-run the same `wget run install.lua ...` command for the role. The installer updates one file
at a time to save disk space. Add `backup` as the last argument to keep
`/.reactor-update-backup` (uses roughly twice the disk). Use `rollback` to restore from that
backup.

### Out of disk space

On the computer, free space before updating:

```text
rm /.reactor-update-backup
rm /.reactor-update-staging
rm /.reactor-install.tmp
rm /logs/events.log.1
```

Optional (loses trend history on the History monitor page):

```text
rm /state/history.state.conf
```

Then re-run the install command.
