# Z-Wave JS UI

Full-featured Z-Wave control panel and MQTT gateway compatible with 500 and 700 series Z-Wave controller adapters. Z-Wave JS runs on many platforms and provides a modern web UI plus flexible integration options.

[![Get it from the Snap Store](https://snapcraft.io/static/images/badges/en/snap-store-black.svg)](https://snapcraft.io/zwave-js-ui)
[![Donate with PayPal](https://giaever.online/ppd.png)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=69NA8SXXFBDBN&source=https://snapcraft.io/zwave-js-ui)

## About This Package

This repository contains a snap package for Z-Wave JS UI, making installation straightforward and enabling automatic updates via the Snap Store.

If you find this snap package useful, please consider:
- Contributing with pull requests
- Donating to support ongoing development:
  - [@giaever-online-iot](https://github.com/sponsors/giaever-online-iot) (Snap maintainer)
  - [@robertsLando](https://github.com/sponsors/robertsLando) (Z-Wave JS UI dev)
  - [@AlCalzone](https://github.com/sponsors/AlCalzone) (Z-Wave JS driver dev)
- Starring this repository

## Getting started

```bash
sudo snap install zwave-js-ui
sudo zwave-js-ui.enable          # the service is disabled until you enable it
```

Then open `http://<host>:8091`. `zwave-js-ui.help` shows the settings and commands;
`sudo zwave-js-ui.ui` is an interactive navigator for settings, service, interfaces and logs.
Settings are snap config: `sudo snap set zwave-js-ui server.port=8092` (the service restarts
itself when a setting it uses changes; `sudo snap unset zwave-js-ui <key>` restores the default).

## Release Channels

The snap uses different channels in the `latest` track to give you control over update frequency:

- **`latest/stable`** — Latest version of the previous major release. Updates only once per major release cycle, typically near the end. For example, when version `b.0.0` is released, version `a.x.y` (the last release of the previous major version) becomes available in stable.

- **`latest/candidate`** — Latest minor or patch release of the current major version. Updates when version `a.b.c` changes to `a.b.d` (patch) or `a.c.0` (minor). This is a rolling release channel for users who want regular updates without major version changes.

- **`latest/edge`** — Development builds. Every build, including experimental and test versions, may be pushed to this channel. It is intended for maintainers and testers only.

For users who want full control and prefer not to receive automatic updates between major and minor releases, use a specific version track (for example, `v9.11`). This allows you to stay on a particular major.minor version and only receive patch updates.

To see all available tracks and channels:
```bash
snap info zwave-js-ui | awk '/channels:/,/^$/' | grep -v '\^' | awk 'NR==1 {h=$0; next} BEGIN{p=""; n=0} {split($1,a,"/"); c=a[1]; if(p!="" && c!=p) lines[n++]="---------------------------"; p=c; lines[n++]=$0} END {print h; for(i=n-1;i>=0;i--) print lines[i]}'
```

To find the default channel:
```bash
snap info zwave-js-ui | awk '/channels:/,/^$/' | grep -v '\^' | awk 'NR==2 {print $1}'
```

To install from a specific channel:
```bash
sudo snap install zwave-js-ui --channel=latest/candidate
```

To switch to a specific version track:
```bash
sudo snap refresh zwave-js-ui --channel=v9.11
```

To switch between channels within a track:
```bash
sudo snap refresh zwave-js-ui --channel=latest/stable
```

## Main Features

### Control Panel UI
Manage your Z-Wave network from the web interface:
- Nodes management: add, remove, and configure nodes
- Firmware updates: apply manufacturer firmware files when available
- Group associations: manage direct node associations
- Full Z-Wave JS API access via the UI

### Gateway & Integration
- Z-Wave to MQTT gateway with configurable exposure of devices
- Backend driver compatible with Home Assistant's official integration
- Home Assistant MQTT discovery support
- Domoticz compatibility via MQTT autodiscovery (beta)

### Security & Management
- HTTPS and user authentication support
- Scene management with MQTT trigger support and timeouts
- Automatic and scheduled backups of NVM and store directory, with optional backups before include/exclude/replace operations

### Monitoring & Debugging
- View debug logs from the UI
- Access files in the persistent store from the UI
- Network graph that visualizes node communication paths

## Commands

| Command | What it does |
| --- | --- |
| `sudo zwave-js-ui.enable` | start the service now and at every boot |
| `sudo zwave-js-ui.disable` | stop it and do not start at boot |
| `sudo zwave-js-ui.restart` | restart the service |
| `sudo zwave-js-ui.exec` | run in the foreground (debug start-up) |
| `sudo zwave-js-ui.ui` | interactive navigator — settings, service, interfaces, logs |
| `sudo zwave-js-ui.logs [zui\|zwjs]` | follow live logs (merged by default) |
| `zwave-js-ui.backup ...` | ship backups off-box (see --help; most need sudo) |
| `zwave-js-ui.help` | this overview (no sudo) |

The snap also integrates with the `code-server` snap to edit files in the persistent store.

## Configuration

Settings are snap config, set with `sudo snap set zwave-js-ui <key>=<value>`:

- `server.*` — listen address, port and SSL: `sudo snap set zwave-js-ui server.host=0.0.0.0`
- `session.*` — session secret and cookie behaviour: `sudo snap set zwave-js-ui server.ssl=true session.cookie-secure=true` (secure cookies need HTTPS)
- `mqtt.name` — MQTT client name: `sudo snap set zwave-js-ui mqtt.name=zwave`
- `timezone` — time zone for the app: `sudo snap set zwave-js-ui timezone=Europe/Oslo`
- `backup.*` — off-box backups: `sudo snap set zwave-js-ui backup.target=file:///mnt/backup`
- `zwave.*` — controller serial port and security keys: `sudo snap set zwave-js-ui zwave.serial-port=/dev/ttyUSB0`

Only `mqtt.name` is snap config; the broker (host, port, user, password) lives in settings.json — edit it with `sudo zwave-js-ui.ui → MQTT broker`.

Unknown keys inside these namespaces are rejected; `sudo snap unset zwave-js-ui <key>` restores a default.
Known settings: `zwave-js-ui.help` (common) or `sudo zwave-js-ui.ui` → Settings (all).

## Interfaces

The service needs `hardware-observe` **and one of** `raw-usb` or `serial-port`.
It refuses to start without them: `sudo zwave-js-ui.enable` and `sudo zwave-js-ui.restart` print
which interface is missing and the command that connects it.

- `raw-usb` (auto-connected from the Snap Store) — USB Z-Wave controller sticks.
- `hardware-observe` (auto-connected) — lets the UI discover devices on the host.
- `serial-port` (manual; needs snapd's experimental hotplug) — a serial controller instead of `raw-usb`.
- `log-observe` (manual) — `zwave-js-ui.logs` reads journald for any log not written to file;
  without it the command exits with the fix: `sudo snap connect zwave-js-ui:log-observe`.
- `gpg-public-keys` (manual) — lets `zwave-js-ui.backup list-keys`/`pick-key` read your `~/.gnupg`; without it they say so and print the connect command.

Manual connections (needed after `snap install --dangerous` of a local build):
```bash
sudo snap connect zwave-js-ui:raw-usb
sudo snap connect zwave-js-ui:hardware-observe
sudo snap connect zwave-js-ui:log-observe
sudo snap connect zwave-js-ui:gpg-public-keys
```

Notes:
- Depending on your distribution you may need to adjust USB device permissions for the controller.
- `raw-usb` grants broad USB access; connect it only if you trust the snap source.

## Reporting Issues

### Z-Wave JS UI (front-end)
For UI or front-end related issues, report at:
- https://github.com/zwave-js/zwave-js-ui/issues

### Z-Wave JS (driver)
For issues with the Z-Wave JS driver, report at:
- https://github.com/zwave-js/node-zwave-js/issues

Before reporting, please:
1. Set the relevant component's log level to `DEBUG`.
2. Enable logging to file.
3. Attach the log file(s) to your issue.

If you're unsure where to report an issue, choose either repo and attach logs for both packages. The issue can be transferred to the correct tracker if needed.

### Snap Package (this repository)
For problems specific to this snap packaging, report at:
- https://github.com/giaever-online-iot/zwave-js-ui/issues
