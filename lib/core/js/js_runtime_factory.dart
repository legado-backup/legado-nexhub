import 'dart:io' show Platform;

import 'js_runtime.dart';
import 'js_runtime_flutter_js.dart';
import 'js_runtime_ohos.dart';

/// 按运行平台创建 JS 运行时：
/// - 鸿蒙（operatingSystem == 'ohos'）：QuickJS 原生桥（dart:ffi）；
/// - 其余平台：flutter_js（行为与改造前完全一致）。
NexJsRuntime createJsRuntime() {
  if (Platform.operatingSystem == 'ohos') {
    return OhosJsRuntime();
  }
  return FlutterJsRuntime();
}
