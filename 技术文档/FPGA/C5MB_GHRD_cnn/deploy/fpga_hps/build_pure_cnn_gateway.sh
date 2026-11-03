#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AI_ROOT=${AI_ROOT:-"$ROOT/../../app/ai_inference"}
CXX=${CXX:-arm-linux-gnueabihf-g++}
OPENCV="$AI_ROOT/vendor/opencv_c5mb"

"$CXX" -std=c++11 -O3 -Wall -Wextra -Werror \
  -D_FILE_OFFSET_BITS=64 \
  -march=armv7-a -mfloat-abi=hard -mfpu=neon \
  -I"$ROOT/card_include" -I"$ROOT" -I"$OPENCV/include" \
  "$ROOT/pure_cnn_runtime.cc" "$ROOT/pure_cnn_gateway.cc" \
  -L"$OPENCV/lib" \
  -Wl,--allow-shlib-undefined \
  -Wl,-rpath,'$ORIGIN/lib:/opt/plite/lib' \
  -l:libopencv_imgcodecs.so.3.4.10 \
  -l:libopencv_imgproc.so.3.4.10 \
  -l:libopencv_core.so.3.4.10 \
  -pthread -ldl -lrt -lm \
  -o "$ROOT/pure_cnn_gateway"

echo "Built $ROOT/pure_cnn_gateway"
