import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:window_manager/window_manager.dart';

import 'platform_service.dart';

/// 窗口能力统一入口：传统桌面走 window_manager，鸿蒙 PC 走自建原生通道。
///
/// 调用方（阅读器等）只关心「是否全屏 / 设置全屏」，不再直接依赖
/// window_manager。视频 PiP 的窗口缩放不在本类职责内（仅传统桌面可用）。
class WindowService {
  const WindowService._();

  static const WindowService instance = WindowService._();

  static const MethodChannel _channel = MethodChannel('nexhub/window_control');

  /// 传统桌面必须在 runApp 之前初始化 window_manager。
  ///
  /// 鸿蒙 PC 走自建通道，无需初始化；移动端直接跳过。
  Future<void> initialize() async {
    if (!PlatformService.instance.isDesktop) return;
    try {
      await windowManager.ensureInitialized();
    } on Object catch (e, st) {
      debugPrint('windowManager.ensureInitialized failed: $e\n$st');
    }
  }

  /// 当前是否处于真窗口全屏。
  ///
  /// 鸿蒙 PC 的通道异常吞掉并返回 false（调用方据此只做保守的退出）。
  Future<bool> isFullScreen() async {
    if (PlatformService.instance.isOHOSPC) {
      try {
        return await _channel.invokeMethod<bool>('isFullScreen') ?? false;
      } on Object {
        return false;
      }
    }
    if (!PlatformService.instance.isDesktop) return false;
    return windowManager.isFullScreen();
  }

  /// 进入 / 退出真窗口全屏。
  ///
  /// Windows 上「必须在事件循环后调用」的既有规避保留在阅读器调用点，
  /// 不搬进本方法。异常交给调用方既有 try/catch。
  Future<void> setFullScreen(bool enabled) async {
    if (PlatformService.instance.isOHOSPC) {
      await _channel.invokeMethod<void>(
        'setFullScreen',
        <String, Object?>{'enabled': enabled},
      );
      return;
    }
    if (!PlatformService.instance.isDesktop) return;
    await windowManager.setFullScreen(enabled);
  }
}
