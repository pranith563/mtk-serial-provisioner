# MTK ADB Serial Provisioner

This is a Linux host-side workaround for MTK development boards that boot with
the duplicate ADB serial `0123456789ABCDEF`.

It detects duplicate devices by ADB `transport_id`, writes a unique serial into
the Android USB gadget configfs descriptor, and restarts `adbd` through Android
init using `setprop ctl.restart adbd`.

This does not change `ro.serialno`, `ro.boot.serialno`, fastboot serial, or
bootloader/factory identity. It only fixes the ADB USB identity that STF sees.

## Behavior

The provisioner is designed to stay running while DeviceFarmer/STF is running.
It handles:

- multiple duplicate-serial MTK devices connected at the same time
- device disconnect and reconnect
- device reboot, where the temporary USB serial is lost
- newly connected duplicate-serial MTK devices

The script only repairs devices currently showing the duplicate serial, by
default `0123456789ABCDEF`. Devices that already have unique ADB serials are
left alone.

## Install

```bash
sudo install -m 0755 mtk-serial-provisioner.sh /usr/local/sbin/mtk-serial-provisioner
sudo install -m 0644 mtk-adb-serial-map.conf.example /etc/mtk-adb-serial-map.conf
sudo install -m 0644 systemd/mtk-serial-provisioner.service /etc/systemd/system/mtk-serial-provisioner.service
```

## Serial Assignment

Manual editing of `/etc/mtk-adb-serial-map.conf` is optional.

By default, `AUTO_ASSIGN=1` is enabled. If a duplicate-serial MTK device appears
on a USB path that is not in the manual map, the script assigns the next
available serial:

```text
MTKADB001
MTKADB002
MTKADB003
```

Automatic assignments are persisted here:

```bash
/var/lib/mtk-serial-provisioner/serial-map.tsv
```

That means disconnect/reconnect and reboot are handled as long as the board
returns on the same physical USB path.

Manual mapping is still supported when you want human-readable or rack-specific
names. Manual mappings always override auto-assigned state.

Edit the mapping file if you want explicit names:

```bash
sudo nano /etc/mtk-adb-serial-map.conf
```

Use physical USB paths from:

```bash
adb devices -l
```

Example:

```text
1-1.2 K6897V1-001
1-1.3 K6897V1-002
```

If a board is moved to a different USB port, it is treated as a new physical
slot unless you add or update the manual mapping. This is unavoidable unless the
board exposes some other unique hardware ID before provisioning.

## Test Once

Keep STF stopped while testing.

```bash
sudo /usr/local/sbin/mtk-serial-provisioner --once
adb devices -l
```

Expected result:

```text
K6897V1-001 device ...
K6897V1-002 device ...
```

## Run Continuously

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mtk-serial-provisioner.service
sudo journalctl -u mtk-serial-provisioner.service -f
```

## DeviceFarmer/STF Ordering

Start this provisioner before the STF provider. If using systemd for STF, add:

```ini
After=mtk-serial-provisioner.service
Requires=mtk-serial-provisioner.service
```

The provisioner should keep running after STF starts so it can repair devices
after reboot or reconnect.

## Notes

- Do not use `adb -s 0123456789ABCDEF` when duplicates are connected.
- This script uses `adb -t <transport_id>` while the serial is duplicated.
- Physical USB path mapping is preferred because `transport_id` changes after
  reconnects.
- If `adb devices -l` does not show a `usb:` field, the script falls back to a
  temporary `transport:<id>` key. That is not stable across reconnects and
  should only be used for manual testing.
