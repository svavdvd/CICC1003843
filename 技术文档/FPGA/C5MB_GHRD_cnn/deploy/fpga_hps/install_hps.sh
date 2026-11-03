#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root" >&2
  exit 1
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEST=/opt/pure_cnn_gateway

test -x "$ROOT/pure_cnn_gateway"
test -f "$ROOT/gateway.ini"
test -f "$ROOT/model/model.json"
test -f "$ROOT/model/parameters.bin"
test -f "$ROOT/model/priors.bin"
test -f "$ROOT/modules/cmadrv.ko"
test -f "$ROOT/lib/libopencv_core.so.3.4.10"
test -f "$ROOT/lib/libopencv_imgproc.so.3.4.10"
test -f "$ROOT/lib/libopencv_imgcodecs.so.3.4.10"

# The old Paddle/NNA service targets the removed QXP core and must not restart.
systemctl disable --now detect.service >/dev/null 2>&1 || true
systemctl stop pl-sort-gateway.service >/dev/null 2>&1 || true

install -d "$DEST/model" "$DEST/modules" "$DEST/lib"
install -m 0755 "$ROOT/pure_cnn_gateway" "$DEST/pure_cnn_gateway"
install -m 0755 "$ROOT/run_pure_cnn_gateway.sh" \
  "$DEST/run_pure_cnn_gateway.sh"
install -m 0644 "$ROOT/gateway.ini" "$DEST/gateway.ini"
install -m 0644 "$ROOT/model/model.json" "$DEST/model/model.json"
install -m 0644 "$ROOT/model/parameters.bin" "$DEST/model/parameters.bin"
install -m 0644 "$ROOT/model/priors.bin" "$DEST/model/priors.bin"
if [ -f "$ROOT/model/labels.txt" ]; then
  install -m 0644 "$ROOT/model/labels.txt" "$DEST/model/labels.txt"
fi
install -m 0644 "$ROOT/modules/cmadrv.ko" "$DEST/modules/cmadrv.ko"
install -m 0644 "$ROOT/lib/"*.so.3.4* "$DEST/lib/"

install -m 0644 "$ROOT/pl-sort-gateway.service" \
  /etc/systemd/system/pl-sort-gateway.service
systemctl daemon-reload
systemctl enable pl-sort-gateway.service

echo "Installed pure CNN gateway in $DEST."
echo "Install the matching soc_system.rbf, reboot, then check:"
echo "  systemctl status pl-sort-gateway.service --no-pager"
echo "  curl http://127.0.0.1:8082/health"