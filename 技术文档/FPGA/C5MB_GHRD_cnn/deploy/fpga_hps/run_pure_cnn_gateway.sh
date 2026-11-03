#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ ! -e /dev/cmadrv0 ]; then
  if ! modprobe cmadrv 2>/dev/null; then
    insmod "$ROOT/modules/cmadrv.ko"
  fi
fi

test -e /dev/cmadrv0
export LD_LIBRARY_PATH="$ROOT/lib:/opt/plite/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$ROOT/pure_cnn_gateway" "$ROOT/gateway.ini"
