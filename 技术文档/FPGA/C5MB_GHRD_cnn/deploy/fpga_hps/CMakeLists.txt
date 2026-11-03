cmake_minimum_required(VERSION 3.13)
project(c5mb_pure_cnn_gateway CXX)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(AI_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../app/ai_inference"
    CACHE PATH "C5MB AI inference support directory")
set(OPENCV_DIR "${AI_ROOT}/vendor/opencv_c5mb")

find_package(Threads REQUIRED)
add_executable(pure_cnn_gateway
  pure_cnn_gateway.cc
  pure_cnn_runtime.cc
)
target_include_directories(pure_cnn_gateway PRIVATE
  card_include
  .
  ${OPENCV_DIR}/include
)
target_compile_definitions(pure_cnn_gateway PRIVATE _FILE_OFFSET_BITS=64)
target_compile_options(pure_cnn_gateway PRIVATE
  -O3 -Wall -Wextra -Werror
  -march=armv7-a -mfloat-abi=hard -mfpu=neon
)
target_link_directories(pure_cnn_gateway PRIVATE ${OPENCV_DIR}/lib)
target_link_libraries(pure_cnn_gateway PRIVATE
  -l:libopencv_imgcodecs.so.3.4.10
  -l:libopencv_imgproc.so.3.4.10
  -l:libopencv_core.so.3.4.10
  Threads::Threads dl rt m
)
target_link_options(pure_cnn_gateway PRIVATE -Wl,--allow-shlib-undefined)
set_target_properties(pure_cnn_gateway PROPERTIES
  BUILD_RPATH "$ORIGIN/lib;/opt/plite/lib"
  INSTALL_RPATH "$ORIGIN/lib;/opt/plite/lib"
)