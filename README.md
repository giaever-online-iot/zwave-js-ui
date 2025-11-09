# Z-Wave JS UI

Full-featured Z-Wave Control Panel and MQTT Gateway compatible with all known 500 and 700 series Z-Wave controller hardware adapters. Z-Wave JS runs on almost anything with a little bit of computing power and a serial port.

[![Get it from the Snap Store](https://snapcraft.io/static/images/badges/en/snap-store-black.svg)](https://snapcraft.io/zwave-js-ui)
[![Donate with PayPal](https://giaever.online/ppd.png)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=69NA8SXXFBDBN&source=https://snapcraft.io/zwave-js-ui)

## About This Package

This is a snap package for Z-Wave JS UI, providing easy installation and automatic updates through the Snap Store.

**If you find this snap package helpful, please consider:**
- Contributing with pull requests
- Making a donation to support ongoing development:
  - [Snap package maintainer](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=69NA8SXXFBDBN&source=https://snapcraft.io/zwave-js-ui)
  - [Z-Wave JS UI developer](https://github.com/sponsors/robertsLando)
  - [Z-Wave JS driver developer](https://github.com/sponsors/AlCalzone)
- Starring this repository

## Main Features

### Control Panel UI
Directly control your nodes and their values from the user interface:
- **Nodes Management**: Add, remove, and configure all nodes in your Z-Wave network
- **Firmware Updates**: Update device firmware using manufacturer-supplied firmware files
- **Group Associations**: Add, edit, and remove direct node associations
- **Z-Wave JS Exposed**: Provides full access to Z-Wave JS's APIs

### Gateway & Integration
- **Full-Featured Z-Wave to MQTT Gateway**: Expose Z-Wave devices to an MQTT broker in a fully configurable manner
- **Home Assistant Integration**: Acts as the backend driver for the official Home Assistant integration, using the same driver and socket server as the official add-on
- **Home Assistant MQTT Discovery**: Alternatively, expose Z-Wave devices to Home Assistant via MQTT discovery
- **Domoticz Support**: Compatible with Domoticz (beta 2021.1) using MQTT Autodiscovery

### Security & Management
- **Secured**: Supports HTTPS and user authentication
- **Scene Management**: Create scenes and trigger them using MQTT APIs with timeout support
- **Automatic/Scheduled Backups**: Scheduled backup of NVM and store directory with optional automatic backups before node inclusion/exclusion/replacement operations

### Monitoring & Debugging
- **Debug Logs in UI**: View debug logs directly from the user interface
- **Access Store Files**: Access files stored in the persistent store folder directly from the UI
- **Network Graph**: Visual map showing how nodes communicate with the controller

## Snap-Specific Features

This snap package includes additional features:
- **Log Reading Command**: Read logs from the terminal regardless of whether you're logging to file
- **Code Server Integration**: Plugs for the `code-server` snap for a full-fledged editor experience with the store folder

## Auto-Connections

When installed from the Snap Store, the following interfaces are automatically connected:
- **`raw-usb`**: Access USB devices, such as Z-Wave controller dongles
- **`hardware-observe`**: Observe your system for devices to easily find them in the UI

> **Note:** These connections are not strictly necessary to run the application. You can disconnect them if desired, though this may affect functionality.

## Reporting Issues

### Z-Wave JS UI Issues
For issues related to the UI or front-end:
- Report at [Z-Wave JS UI GitHub Issues](https://github.com/zwave-js/zwave-js-ui/issues)

### Z-Wave JS Driver Issues
For issues related to the Z-Wave JS driver:
- Report at [Z-Wave JS GitHub Issues](https://github.com/zwave-js/node-zwave-js/issues)

**Before reporting:**
1. Set the log level to `DEBUG` for the respective component
2. Enable logging to file
3. Attach the log file with your issue

If you're unsure where to report, choose either repository and attach logs for both packages. The issue will be transferred to the correct tracker if needed.

### Snap Package Issues
For issues specific to this snap package:
- Report at [giaever-online-iot/zwave-js-ui GitHub Issues](https://github.com/giaever-online-iot/zwave-js-ui/issues)
