import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../platform/platform_service.dart';

/// 播放内核运行时闸门（平台初始化 + 内核可用性）。
///
/// 规格 §7：把散落的 `MediaKit.ensureInitialized()` 调用收口到此，
/// 由工厂 / 页面统一经此判断，避免鸿蒙侧误加载不存在的原生库。
///
/// 鸿蒙内核（libmpv.so）由 `media_kit_libs_ohos` 随 HAP 打进 `libs/arm64-v8a/`
/// （构建前用 `tool/fetch_ohos_libmpv.ps1` 预置，详见《播放内核选型结论》）。
/// 内核已验证随包可达，**默认开启**；排查内核问题时可显式退回降级提示：
/// ```powershell
/// flutter build hap --debug --target-platform ohos-arm64 `
///   --dart-define=NEXHUB_OHOS_PLAYER=false
/// ```
/// 内核加载失败时（如 .so 未打入）由 [PlayerFactory] 捕获降级为占位后端，
/// 不会崩溃。
abstract final class PlayerRuntime {
  /// 鸿蒙播放内核开关（默认开，可用 `NEXHUB_OHOS_PLAYER=false` 关闭）。
  static const bool ohosPlayerEnabled =
      bool.fromEnvironment('NEXHUB_OHOS_PLAYER', defaultValue: true);

  /// 是否具备 media_kit 播放内核。
  ///
  /// 非鸿蒙平台恒为 true；鸿蒙取决于 [ohosPlayerEnabled]。
  static bool get available =>
      !PlatformService.instance.isOHOS || ohosPlayerEnabled;

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
