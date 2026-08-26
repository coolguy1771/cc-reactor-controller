# Remote monitor deployment

This build uses one Advanced Computer beside the reactor and one Advanced Computer beside the
monitors. Both computers need an Ender Modem. The reactor/turbine ports stay wired to the reactor
computer; the monitors stay wired to the display computer.

## Reactor computer

Copy these items into the reactor computer's filesystem root:

- `src/`
- `startup.lua`

In-game, configure the shared secret:

```text
mkdir /overrides
edit /overrides/control.override.conf
```

Use this file content, replacing the sample value:

```lua
{
  remoteSecret = "use-your-own-long-random-secret-here",
  remoteClients = {
    [42] = "control", -- replace 42 with the display computer's `id`
  },
}
```

Attach an Ender Modem and reboot. The terminal should report:

```text
Remote display server: reactor-controller via <modem name>
```

## Control-room display computer

Copy these files into the display computer's filesystem root:

- `remote-display.lua`
- Copy `remote-startup.lua` as `startup.lua`

Attach an Ender Modem. Connect the Advanced Monitor to this computer directly or through a local
wired-modem network, then reboot. The first run creates `/remote-display.conf` and stops.

Run:

```text
edit /remote-display.conf
```

Set `secret` to the exact same value used on the reactor computer and reboot again. Leave
`protocol` and `host` at their defaults unless you changed the corresponding controller settings.
The display reconnects automatically after controller restarts or chunk unloads.

## Independent watchdog computer

Install the watchdog on a third computer (see [WGET-SETUP.md](WGET-SETUP.md)). Connect its configured redstone side to an
Extreme Reactors redstone port/relay whose asserted signal shuts down the reactor. On first boot,
edit `/watchdog.conf`, set the same secret and correct output side, then set
`watchdogEnabled = true` in the controller override. The watchdog starts asserted and only clears
after three consecutive healthy controller heartbeats.

## Dedicated-server filesystem

CC:Tweaked normally stores each computer beneath:

```text
<world>/computercraft/computer/<computer-id>/
```

Stop the Minecraft server before replacing a computer's files, or use in-game `wget run` per
[WGET-SETUP.md](WGET-SETUP.md). Back up each computer directory before manual edits. Use the in-game
`id` command on each computer to identify its directory.

## Failure behavior

- Reactor and turbine control continues locally when the Ender Modem link fails.
- The display shows a red link-lost warning after the timeout.
- A client that disappears is removed from the controller after 15 seconds and reconnects through
  its next hello message.
- Shared-secret checks reject accidental or unauthorized touch commands, but Rednet traffic is not
  encrypted.
