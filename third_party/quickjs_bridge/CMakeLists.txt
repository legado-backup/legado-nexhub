# QuickJS 桥（鸿蒙原生库）
#
# 由鸿蒙壳工程（ohos/entry 的 externalNativeOptions）在 HAP 构建时编译，
# 产物 libnexhub_quickjs.so 随 HAP 打包，供 lib/core/js/js_runtime_ohos.dart
# 通过 dart:ffi 加载。
#
# 源码来源：
#   - quickjs/  ：QuickJS 2021-03-27（MIT，https://bellard.org/quickjs）
#   - 桥接形态  ：参考 abner/quickjs-c-bridge（MIT）与 flutter_js 0.8.x 的
#                 Android C 桥（com.abner.ffi / libfastdev_quickjs_runtime），
#                 本仓库重写为 nexhub_quickjs_api.cpp（新增微任务泵）。
#
# 说明：只编译运行时必需的最小文件集（cutils/libregexp/libunicode/quickjs），
# 不含 quickjs-libc（无宿主 std/os 模块需求）。

cmake_minimum_required(VERSION 3.17)
project(nexhub_quickjs_bridge LANGUAGES CXX C)

set(QUICKJS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/quickjs")

add_library(nexhub_quickjs_bridge SHARED
  "${QUICKJS_DIR}/cutils.c"
  "${QUICKJS_DIR}/libregexp.c"
  "${QUICKJS_DIR}/libunicode.c"
  "${QUICKJS_DIR}/quickjs.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/nexhub_quickjs_api.cpp"
)

set_target_properties(nexhub_quickjs_bridge PROPERTIES
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  OUTPUT_NAME nexhub_quickjs
  POSITION_INDEPENDENT_CODE ON
  VISIBILITY_INLINES_HIDDEN YES
)

target_compile_features(nexhub_quickjs_bridge PUBLIC cxx_std_17)
target_compile_definitions(nexhub_quickjs_bridge PRIVATE
  CONFIG_VERSION="2021-03-27"
)
target_compile_options(nexhub_quickjs_bridge PRIVATE
  $<$<COMPILE_LANGUAGE:C>:-Wno-implicit-const-int-float-conversion>
  $<$<COMPILE_LANGUAGE:C>:-Wno-int-conversion>
  $<$<COMPILE_LANGUAGE:C>:-Wno-unused-but-set-variable>
  $<$<COMPILE_LANGUAGE:C>:-Wno-unused-variable>
)

# 隐藏符号 + 绑定到自身：避免与宿主进程里其它 JS 引擎（如 libmpv 的 mujs）
# 的同名符号（js_malloc 等）冲突。
if(UNIX AND NOT APPLE)
  target_link_options(nexhub_quickjs_bridge PRIVATE
    "-Wl,-Bsymbolic-functions"
  )
endif()
