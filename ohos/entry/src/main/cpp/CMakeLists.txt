# NexHub 鸿蒙壳工程的原生构建入口。
#
# 仅负责把 third_party/quickjs_bridge（QuickJS + dart:ffi C API）编成
# libnexhub_quickjs.so，随 HAP 打包供 lib/core/js/js_runtime_ohos.dart 加载。
# 由 ohos/entry/build-profile.json5 的 buildOption.externalNativeOptions 挂接。
cmake_minimum_required(VERSION 3.17)
project(nexhub_ohos_native LANGUAGES CXX C)

add_subdirectory(
  "${CMAKE_CURRENT_LIST_DIR}/../../../../../third_party/quickjs_bridge"
  "${CMAKE_CURRENT_BINARY_DIR}/quickjs_bridge"
)

# 模拟器（x86_64）补齐 flutter_inappwebview_ohos 的 NAPI 垫片：上游模块只按
# arm64 构建，但插件 ETS 在注册时静态导入 libinappwebview.so，缺失会启动即失败。
if(OHOS_ARCH STREQUAL "x86_64")
  add_library(inappwebview SHARED
    "${CMAKE_CURRENT_LIST_DIR}/inappwebview_napi/napi_init.cpp"
  )
  target_link_libraries(inappwebview PUBLIC libace_napi.z.so libuv.so)
endif()
