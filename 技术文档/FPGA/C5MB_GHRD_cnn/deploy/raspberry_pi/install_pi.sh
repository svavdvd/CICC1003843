#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root" >&2
  exit 1
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CAMERA_DIR=/opt/MVS/Samples/aarch64/Python/GrabImage
ARM_DIR=/home/jetson/Desktop

test -f "$ROOT/camera_api_pl.py"
test -f "$ROOT/pl_dispatch.py"
test -f "$ROOT/arm_api_ack.py"
test -f "$ROOT/config.ini"

backup_once() {
  target=$1
  if [ -e "$target" ] && [ ! -e "$target.before_pl" ]; then
    cp -a "$target" "$target.before_pl"
  fi
}

backup_once "$CAMERA_DIR/api.py"
backup_once "$CAMERA_DIR/config.ini"
backup_once "$ARM_DIR/api.py"
backup_once "$ARM_DIR/config.ini"

install -m 0644 "$ROOT/camera_api_pl.py" "$CAMERA_DIR/api.py"
install -m 0644 "$ROOT/pl_dispatch.py" "$CAMERA_DIR/pl_dispatch.py"
install -m 0644 "$ROOT/config.ini" "$CAMERA_DIR/config.ini"
install -m 0644 "$ROOT/arm_api_ack.py" "$ARM_DIR/api.py"
install -m 0644 "$ROOT/config.ini" "$ARM_DIR/config.ini"
install -m 0644 "$ROOT/pl-arm-control.service" \
  /etc/systemd/system/pl-arm-control.service

systemctl daemon-reload
systemctl enable pl-arm-control.service
systemctl restart pl-arm-control.service
if systemctl list-unit-files detect-api.service >/dev/null 2>&1; then
  systemctl restart detect-api.service
fi

echo "Installed Raspberry Pi PL dispatcher and actuator service."
echo "Verify /dev/BAOJING, /dev/XIPAN and the arm UART before live motion."
