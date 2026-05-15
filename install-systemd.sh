#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -d -m 0755 /usr/local/sbin
install -d -m 0755 /usr/local/share/mtk-serial-provisioner
install -d -m 0755 /etc/systemd/system
install -d -m 0755 /var/lib/mtk-serial-provisioner

install -m 0755 "$SCRIPT_DIR/mtk-serial-provisioner.sh" \
  /usr/local/sbin/mtk-serial-provisioner

install -m 0644 "$SCRIPT_DIR/systemd/mtk-serial-provisioner.service" \
  /etc/systemd/system/mtk-serial-provisioner.service

install -m 0644 "$SCRIPT_DIR/README.md" \
  /usr/local/share/mtk-serial-provisioner/README.md

if [[ ! -e /etc/mtk-adb-serial-map.conf ]]; then
  install -m 0644 "$SCRIPT_DIR/mtk-adb-serial-map.conf.example" \
    /etc/mtk-adb-serial-map.conf
else
  echo "Keeping existing /etc/mtk-adb-serial-map.conf"
fi

systemctl daemon-reload
systemctl enable --now mtk-serial-provisioner.service

echo "Installed and started mtk-serial-provisioner.service"
systemctl --no-pager --full status mtk-serial-provisioner.service
