import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel;

import 'platform_service.dart';

/// 鸿蒙后台长任务（`dataTransfer`）：下载期间申请后台保活。
///
/// 引用计数对应在跑/排队的下载任务；计数从 0 变 1 时申请
/// `backgroundTaskManager.startBackgroundRunning`，归零时停止。
/// 任务交接（完成一个启动下一个）时先申请再释放，避免系统面板闪烁。
/// 其他平台为空操作。
class BackgroundTask {
  BackgroundTask._();

  static const MethodChannel _channel = MethodChannel('nexhub/background_task');

  static int _holders = 0;

  /// 串行化原生调用，保证 start / stop 顺序与计数变化一致。
  static Future<void> _queue = Future<void>.value();

  static void acquire() {
    if (!PlatformService.instance.isOHOS) return;
    _holders++;
    if (_holders == 1) _enqueue(true);
  }

  static void release() {
    if (!PlatformService.instance.isOHOS || _holders == 0) return;
    _holders--;
    if (_holders == 0) _enqueue(false);
  }

  static void _enqueue(bool start) {
    _queue = _queue.then((_) async {
      try {
        await _channel.invokeMethod<void>(start ? 'start' : 'stop');
      } on Object catch (e) {
        debugPrint('BackgroundTask.${start ? 'start' : 'stop'} failed: $e');
      }
    });
  }
}
