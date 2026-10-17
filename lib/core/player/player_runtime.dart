import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../platform/platform_service.dart';

/// 播放内核运行时闸门（平台初始化 + 内核可用性）。
///
/// 规格 §7：把散落的 `MediaKit.ensureInitialized()` 调用收口到此，
/// 由工厂 / 页面统一经此判断，避免鸿蒙侧误加载不存在的原生库。
///
/// 鸿蒙在阶段 4（播放器攻坚）前没有 libmpv 内核：
/// - [available] 为 false 时不得创建任何 media_kit `Player`（原生库缺失会崩）；
/// - 视频播放入口统一展示「暂不支持」降级提示（见 video_player_screen）。
abstract final class PlayerRuntime {
  /// 是否具备 media_kit 播放内核。
  ///
  /// 阶段 4 落地 AVPlayer/libmpv 后，此处按实际内核实现改写。
  static bool get available => !PlatformService.instance.isOHOS;

  static bool _initialized = false;

  /// 幂等初始化播放内核（可安全重复调用）。
  ///
  /// - 鸿蒙：直接跳过（无内核）；
  /// - 其余平台：初始化失败只打日志（历史行为：内核异常不应阻塞应用启动，
  ///   仅视频播放不可用，浏览 / 阅读等核心功能仍正常）。
  static void ensureInitialized() {
    if (!available || _initialized) return;
    _initialized = true;
    try {
      MediaKit.ensureInitialized();
    } catch (e, st) {
      debugPrint('MediaKit.ensureInitialized failed: $e\n$st');
    }
  }
}

/// 当前平台没有可用播放内核时抛出（入口据此展示降级提示）。
class PlayerUnavailableException implements Exception {
  const PlayerUnavailableException();

  @override
  String toString() => 'PlayerUnavailableException: 当前平台暂无播放内核';
}
