#!/usr/bin/env bash
set -euo pipefail

# Host-side MTK duplicate ADB serial provisioner.
#
# Purpose:
#   Some MTK development boards boot with the same ADB serial, commonly
#   0123456789ABCDEF. DeviceFarmer/STF cannot safely manage duplicate ADB
#   serials on the same provider. This script detects such devices by
#   transport_id, writes a unique USB gadget serial, and restarts adbd via init.
#
# Safety:
#   This script does not write raw block devices and does not modify bootloader
#   storage. It only writes the Android USB gadget configfs serial descriptor.

DUPLICATE_SERIAL="${DUPLICATE_SERIAL:-0123456789ABCDEF}"
MAPPING_FILE="${MAPPING_FILE:-/etc/mtk-adb-serial-map.conf}"
STATE_DIR="${STATE_DIR:-/run/mtk-serial-provisioner}"
POLL_SECONDS="${POLL_SECONDS:-3}"
REQUIRE_MTK="${REQUIRE_MTK:-1}"
LOG_PREFIX="${LOG_PREFIX:-mtk-serial-provisioner}"

mkdir -p "$STATE_DIR"

log() {
  printf '%s [%s] %s\n' "$(date -Is)" "$LOG_PREFIX" "$*" >&2
}

die() {
  log "fatal: $*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

adb_cmd() {
  adb "$@"
}

load_mapping() {
  [[ -r "$MAPPING_FILE" ]] || die "mapping file not readable: $MAPPING_FILE"
}

target_serial_for_key() {
  local key="$1"
  awk -v key="$key" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $1 == key { print $2; found=1; exit }
    END { if (!found) exit 1 }
  ' "$MAPPING_FILE"
}

device_field() {
  local transport_id="$1"
  local prop="$2"
  adb_cmd -t "$transport_id" shell "getprop $prop" 2>/dev/null | tr -d '\r'
}

is_mtk_device() {
  local transport_id="$1"
  local hardware manufacturer platform

  hardware="$(device_field "$transport_id" ro.boot.hardware || true)"
  manufacturer="$(device_field "$transport_id" ro.soc.manufacturer || true)"
  platform="$(device_field "$transport_id" ro.board.platform || true)"

  printf '%s\n%s\n%s\n' "$hardware" "$manufacturer" "$platform" | grep -Eiq 'mt[0-9]|mediatek'
}

usb_path_for_transport() {
  local transport_id="$1"
  local line usb_path

  line="$(adb_cmd devices -l | awk -v tid="transport_id:${transport_id}" '$0 ~ tid { print; exit }')"
  usb_path="$(printf '%s\n' "$line" | sed -n 's/.* usb:\([^ ]*\).*/\1/p')"

  if [[ -n "$usb_path" ]]; then
    printf '%s\n' "$usb_path"
  else
    printf 'transport:%s\n' "$transport_id"
  fi
}

transport_for_key() {
  local key="$1"

  if [[ "$key" == transport:* ]]; then
    printf '%s\n' "${key#transport:}"
    return 0
  fi

  adb_cmd devices -l \
    | awk -v usb="usb:${key}" '
        $0 ~ usb && $2 == "device" {
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^transport_id:/) {
              split($i, parts, ":")
              print parts[2]
              exit
            }
          }
        }
      '
}

wait_for_transport_key() {
  local key="$1"
  local attempt transport_id

  for attempt in $(seq 1 20); do
    sleep 1
    transport_id="$(transport_for_key "$key")"
    if [[ -n "$transport_id" ]]; then
      printf '%s\n' "$transport_id"
      return 0
    fi
  done

  return 1
}

list_duplicate_transport_ids() {
  adb_cmd devices -l \
    | awk -v serial="$DUPLICATE_SERIAL" '
        $1 == serial && $2 == "device" {
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^transport_id:/) {
              split($i, parts, ":")
              print parts[2]
            }
          }
        }
      '
}

ensure_root_transport() {
  local transport_id="$1"
  local usb_path="$2"
  local uid new_transport_id

  uid="$(adb_cmd -t "$transport_id" shell 'id -u' 2>/dev/null | tr -d '\r' || true)"
  if [[ "$uid" == "0" ]]; then
    printf '%s\n' "$transport_id"
    return 0
  fi

  adb_cmd -t "$transport_id" root >/dev/null 2>&1 || true
  new_transport_id="$(wait_for_transport_key "$usb_path" || true)"

  if [[ -z "$new_transport_id" ]]; then
    log "could not rediscover transport after adb root for key=$usb_path"
    return 1
  fi

  uid="$(adb_cmd -t "$new_transport_id" shell 'id -u' 2>/dev/null | tr -d '\r' || true)"
  if [[ "$uid" != "0" ]]; then
    log "device key=$usb_path is not root after adb root; uid=$uid"
    return 1
  fi

  printf '%s\n' "$new_transport_id"
}

restart_adbd_for_transport() {
  local transport_id="$1"
  adb_cmd -t "$transport_id" shell 'setprop ctl.restart adbd' >/dev/null
}

write_gadget_serial() {
  local transport_id="$1"
  local usb_path="$2"
  local target_serial="$3"
  local root_transport_id

  root_transport_id="$(ensure_root_transport "$transport_id" "$usb_path")"

  adb_cmd -t "$root_transport_id" shell \
    "test -w /config/usb_gadget/g1/strings/0x409/serialnumber" >/dev/null

  adb_cmd -t "$root_transport_id" shell \
    "echo '$target_serial' > /config/usb_gadget/g1/strings/0x409/serialnumber"

  adb_cmd -t "$root_transport_id" shell \
    "setprop persist.vendor.serialno '$target_serial'" >/dev/null || true

  restart_adbd_for_transport "$root_transport_id"
}

wait_for_serial() {
  local target_serial="$1"
  local attempt

  for attempt in $(seq 1 20); do
    sleep 1
    if adb_cmd devices -l | awk -v serial="$target_serial" '$1 == serial && $2 == "device" { found=1 } END { exit found ? 0 : 1 }'; then
      return 0
    fi
  done

  return 1
}

provision_transport() {
  local transport_id="$1"
  local usb_path target_serial

  if [[ "$REQUIRE_MTK" == "1" ]] && ! is_mtk_device "$transport_id"; then
    log "transport_id=$transport_id has duplicate serial but does not look MTK; skipping"
    return 0
  fi

  usb_path="$(usb_path_for_transport "$transport_id")"
  target_serial="$(target_serial_for_key "$usb_path" || true)"

  if [[ -z "$target_serial" ]]; then
    log "no mapping for key '$usb_path'; add it to $MAPPING_FILE"
    return 0
  fi

  log "provisioning transport_id=$transport_id key=$usb_path target_serial=$target_serial"
  write_gadget_serial "$transport_id" "$usb_path" "$target_serial"

  if wait_for_serial "$target_serial"; then
    log "verified target_serial=$target_serial"
  else
    log "failed to verify target_serial=$target_serial after adbd restart"
    return 1
  fi
}

run_once() {
  local transport_id

  adb_cmd start-server >/dev/null
  mapfile -t transport_ids < <(list_duplicate_transport_ids)

  for transport_id in "${transport_ids[@]:-}"; do
    [[ -n "$transport_id" ]] || continue
    provision_transport "$transport_id" || true
  done
}

usage() {
  cat <<EOF
Usage:
  $0 --once
  $0 --watch

Environment:
  DUPLICATE_SERIAL  Serial to repair. Default: 0123456789ABCDEF
  MAPPING_FILE      Port/path mapping file. Default: /etc/mtk-adb-serial-map.conf
  POLL_SECONDS      Watch interval. Default: 3
  REQUIRE_MTK       Require MTK-ish getprop match before provisioning. Default: 1

Mapping file format:
  <adb-usb-path-or-transport-fallback> <target-serial>

Example:
  1-1.2 K6897V1-001
  1-1.3 K6897V1-002
EOF
}

main() {
  need_cmd adb
  need_cmd awk
  need_cmd sed
  load_mapping

  case "${1:-}" in
    --once)
      run_once
      ;;
    --watch)
      log "watching for duplicate serial '$DUPLICATE_SERIAL'"
      while true; do
        run_once
        sleep "$POLL_SECONDS"
      done
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
