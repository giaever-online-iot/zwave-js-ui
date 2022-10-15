# Zwave JS UI

Fully configurable Zwave to MQTT Gateway and Control Panel.

[![Get it from the Snap Store](https://snapcraft.io/static/images/badges/en/snap-store-black.svg)](https://snapcraft.io/zwave-js-ui)
[![Donate with PayPal](https://giaever.online/ppd.png)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=69NA8SXXFBDBN&source=https://snapcraft.io/zwave-js-ui)

**If you're happy with this snap package, please consider to**
- contribute with PR's,
- make a donation (any contribution will help keep these projects alive!) to the
  * Snap package [maintainer](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=69NA8SXXFBDBN&source=https://snapcraft.io/zwave-js-ui)
  * ZUI [developer](https://github.com/sponsors/robertsLando)
  * Zwave JS [developer](https://github.com/sponsors/AlCalzone)
- starring this repository

Full featured Z-Wave Control Panel and MQTT Gateway compatible with all known 500 and 
700 series Z-Wave controller hardware adapters, Z-Wave JS runs on almost anything with 
a little bit of computing power and a serial port.

# Main features
- Control Panel UI: Directly control your nodes and their values from the UI, including:
  - Nodes management: Add, remove, and configure all nodes in your Z-Wave network
  - Firmware updates: Update device firmware using manufacturer-supplied firmware files
  - Groups associations: Add, edit, and remove direct node associations
  - Z-Wave JS Exposed: Provides full-access to Z-Wave JS's APIs
- Full-Featured Z-Wave to MQTT Gateway: Expose Z-Wave devices to an MQTT broker in a 
  fully configurable manner
- Secured: Supports HTTPS and user authentication
- Scene Management: Create scenes and trigger them by using MQTT apis (with timeout 
  support)
- Debug Logs in the UI: See debug logs directly from the UI
- Access Store Files in the UI: Access the files are stored in the persistent store 
  folder directly from the UI
- Network Graph: Provides a beautiful map showing how nodes are communicating with the 
  controller
- Supports the Official Home Assistant Integration: Can act as the backend driver for 
  the official Home Assistant integration, using the same driver and socket server as 
  the official addon
- Supports Home Assistant Discovery via MQTT: In lieu of the official integation, can 
  be used to expose Z-Wave devices to Home Assistant via MQTT discovery.
- Supported by Domoticz (beta 2021.1): Using MQTT Autodiscovery.
- Automatic/Scheduled backups: Scheduled backup of NVM and store directory. It's also 
  possible to enable automatic backups of NVM before every node inclusion/exclusion/
  replace, this ensures to create a safe restore point before any operation that can 
  cause a network corruption.

## Additions with the snap
- Command to read the log from the terminal independent of if you're logging to file 
  or not
- Plugs for the `code-server` snap, if you want a full-fledge editor experience for 
  the «store-folder»

# Auto-connections (only if installed from the Snap store)
- `raw-usb`: To access USB devices, such as Z-wave controller dongles
- `hardware-observe`: To observe your system for devices, to easily find them in the UI

**Note:** None of these connections are necessary to run the app, so you can disconnect 
them as you like, but please note that it might change the experience within the software.

# Issues
If your issue is with 
- the UI/front-end, report them with [Zwave JS UI](https://github.com/zwave-js/zwave-js-ui/issues)
- the driver, report them with the driver [Zwave JS](https://github.com/zwave-js/node-zwave-js/issues).

Make sure you have set the log level to `DEBUG` for the respective unit and that you are
logging to file, and attach it with your issue.

If you're not sure, just report it witin any of the above, but attach logs for both 
packages. It will be transferred if you reported it within the wrong tracker.
## Issues with the snap package
Report it with the [github repository](https://github.com/giaever-online-iot/zwave-js-ui/issues).
