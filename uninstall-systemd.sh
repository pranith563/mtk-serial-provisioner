#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

systemctl disable --now mtk-serial-provisioner.service 2>/dev/null || true

rm -f /etc/systemd/system/mtk-serial-provisioner.service
rm -f /usr/local/sbin/mtk-serial-provisioner
rm -rf /usr/local/share/mtk-serial-provisioner

systemctl daemon-reload

cat <<'EOF'
Uninstalled mtk-serial-provisioner.service.

Preserved operator state/config:
  /etc/mtk-adb-serial-map.conf
  /var/lib/mtk-serial-provisioner/

Remove those manually if you also want to delete assignments/config.
EOF
