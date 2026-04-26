<img width="936" height="350" alt="image" src="https://github.com/user-attachments/assets/fc0db82b-9136-401c-873e-357682dae404" />

# USBshield

usbshield is a wrapper for [usbguard](https://usbguard.github.io/) that provides an interactive interface for authorizing USB devices and writing permanent allow rules. usbguard is the underlying daemon that blocks unauthorized devices at the kernel level; devices receive power but are not exposed to the OS until a certificate is created to authorize the device for data transfer.

## Requirements

- **OS:** Linux (systemd-based distributions)
- **Shell:** Bash 4.0 or later
- **Dependencies:** `usbguard` (installed by `setup.sh`), `column` (util-linux), `tput` (ncurses)
- **Privileges:** Root (`usbshield` re-execs itself with `sudo` automatically)

## Setup

Run `setup.sh` once to install usbguard, seed an initial policy from currently connected devices, and enable the service:

```bash
sudo ./setup.sh
```

This handles package installation across apt, dnf/yum, zypper, pacman, apk, and portage-based systems. It also installs `usbshield` to `/usr/local/bin/`.

## usbshield

Interactively authorize a connected USB device and write a permanent rule to `/etc/usbguard/rules.conf`.

```
sudo ./usbshield
```

### What it does

1. Enumerates connected USB devices, skipping root hubs (VID `1d6b`), Intel integrated BT/WiFi (`8087`), and AMD integrated controllers (`1022`).
2. Displays a table with manufacturer, product, serial, VID:PID, device class, interface classes, power draw (mA), and port.
3. Flags devices `[!]` where HID is combined with Mass Storage, Communications/CDC, Video, Printer, or Vendor-Specific interfaces, a pattern associated with BadUSB attacks.
4. Prompts you to select a device by number (60-second timeout).
5. Prompts for a **Label**, a short human-readable name (e.g. `Xbox-Controller`). Only `[a-zA-Z0-9._-]` characters are kept.
6. Verifies the selected device is still connected before proceeding.
7. Runs `usbguard generate-policy`, checks the selected device appears in the output, and annotates its rule with your label.
8. Backs up the existing `rules.conf` to `rules.conf.bak.<timestamp>-<random>` with `600` permissions, then atomically writes the new policy.
9. Restarts USBGuard if it is running.

### Power display

`bMaxPower` is reported in mA. The value is always the raw field multiplied by 2, per the USB specification (USB 2.0 through 3.2 all use 2 mA units for `bMaxPower`).

### BadUSB indicator

The `[!]` flag appears on any device that exposes a HID interface alongside one or more of: Mass Storage, Communications (CDC), Video, Printer, or Vendor-Specific. This combination is the functional signature of most BadUSB-style attacks. A device with multiple interfaces that are all the same class (e.g. a keyboard with two HID endpoints) will not be flagged.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Device authorized successfully |
| 1 | Error (aborted, invalid input, device not found, policy failure) |
| 2 | No external USB devices detected (not an error condition) |

## List authorized devices

```bash
cat /etc/usbguard/rules.conf
```

Each rule looks like:

```
# USB-Controller
allow id 045e:02fd ...
```

## Remove a device

1. Open the rules file:
   ```bash
   sudo nano /etc/usbguard/rules.conf
   ```
2. Delete the comment line and the `allow` line for the device.
3. Restart USBGuard:
   ```bash
   sudo systemctl restart usbguard
   ```

## One-off allow/block (no permanent rule)

```bash
sudo usbguard list-devices          # show all devices and their IDs
sudo usbguard allow-device <ID>     # allow for current session only
sudo usbguard block-device <ID>     # block for current session only
```
---

#### Please report all issues

[https://github.com/andrewarabian/usb-warden/issues](https://github.com/andrewarabian/usbshield/issues)

---
