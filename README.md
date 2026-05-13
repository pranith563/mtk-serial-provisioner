# MTK ADB Serial Provisioner

This is a Linux host-side workaround for MTK development boards that boot with
the duplicate ADB serial `0123456789ABCDEF`.

It detects duplicate devices by ADB `transport_id`, writes a unique serial into
the Android USB gadget configfs descriptor, and restarts `adbd` through Android
init using `setprop ctl.restart adbd`.

This does not change `ro.serialno`, `ro.boot.serialno`, fastboot serial, or
bootloader/factory identity. It only fixes the ADB USB identity that STF sees.

## Install

```bash
sudo install -m 0755 mtk-serial-provisioner.sh /usr/local/sbin/mtk-serial-provisioner
sudo install -m 0644 mtk-adb-serial-map.conf.example /etc/mtk-adb-serial-map.conf
sudo install -m 0644 systemd/mtk-serial-provisioner.service /etc/systemd/system/mtk-serial-provisioner.service
```

Edit the mapping file:

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
