# Z-Wave JS UI

Full-featured Z-Wave control panel and MQTT gateway compatible with 500 and 700 series Z-Wave controller adapters. Z-Wave JS runs on many platforms and provides a modern web UI plus flexible integration options.

[![Get it from the Snap Store](https://snapcraft.io/static/images/badges/en/snap-store-black.svg)](https://snapcraft.io/zwave-js-ui)
[![Donate with PayPal](https://giaever.online/ppd.png)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=69NA8SXXFBDBN&source=https://snapcraft.io/zwave-js-ui)

## About This Package

This repository contains a snap package for Z-Wave JS UI, making installation straightforward and enabling automatic updates via the Snap Store.

If you find this snap package useful, please consider:
- Contributing with pull requests
- Donating to support ongoing development:
  - Snap package maintainer: https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=69NA8SXXFBDBN
  - Z-Wave JS UI developer: https://github.com/sponsors/robertsLando
  - Z-Wave JS driver developer: https://github.com/sponsors/AlCalzone
- Starring this repository

## Release Channels

The snap uses different channels in the `latest` track to give you control over update frequency:

- **`latest/stable`** — Latest version of the previous major release. Updates only once per major release cycle, typically near the end. For example, when version `b.0.0` is released, version `a.x.y` (the last release of the previous major version) becomes available in stable.

- **`latest/candidate`** — Latest minor or patch release of the current major version. Updates when version `a.b.c` changes to `a.b.d` (patch) or `a.c.0` (minor). This is a rolling release channel for users who want regular updates without major version changes.

- **`latest/edge`** and **`latest/edge/dev`** — Development builds. Every build, including experimental and test versions, may be pushed to these channels. These channels are intended for maintainers and testers only.

For users who want full control and prefer not to receive automatic updates between major and minor releases, use a specific version track (for example, `v9.11`). This allows you to stay on a particular major.minor version and only receive patch updates.

To see all available tracks and channels:
```bash
snap info zwave-js-ui
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

## Snap-Specific Features

This snap includes features that simplify running and managing Z-Wave JS UI on systems that use snaps:
- Read logs from the terminal regardless of whether the application logs to file
- Optional integration with the `code-server` snap to edit files in the persistent store

## Auto-Connections

When installed from the Snap Store, the snap automatically connects two interfaces to provide a convenient out-of-the-box experience:

- `raw-usb` — Grants access to USB devices (for example, Z-Wave controller dongles).
- `hardware-observe` — Allows the snap to observe hardware events so the UI can discover devices on the host.

These connections are automatically set for convenience and to provide a good initial experience, but they are not strictly required. If you prefer tighter isolation you can disconnect them; note that doing so may restrict functionality (for example, the UI may not detect USB dongles and the snap won't be able to access a controller via USB).

Manual connect/disconnect examples:
- To manually connect (useful if you installed the snap locally or built it yourself):
  ```bash
  sudo snap connect zwave-js-ui:raw-usb
  sudo snap connect zwave-js-ui:hardware-observe
  ```
- To disconnect:
  ```bash
  sudo snap disconnect zwave-js-ui:raw-usb
  sudo snap disconnect zwave-js-ui:hardware-observe
  ```

Additional notes:
- If you install the snap outside the Snap Store (for example with `snap install --dangerous`), the interfaces might not be auto-connected and you may need to run the connect commands above.
- Depending on your distribution, you may also need to adjust USB device permissions or add your user to a serial/dialout group for direct access to the controller device node.
- Granting the `raw-usb` interface gives the snap broad access to USB devices. Only enable it if you trust the snap source and understand the implications.

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
