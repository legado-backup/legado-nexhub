import 'dart:async';

import 'package:flutter/services.dart';

import '../platform/platform_service.dart';

/// 鸿蒙壁纸主色来源（Material You / 莫奈 seed）。
///
/// `dynamic_color` 上游没有 ohos 实现，鸿蒙端取不到系统动态色；这里通过
/// 应用级 MethodChannel 读取壁纸服务缓存的主色。仅 OHOS 调用，其他平台
/// （Android 走 `DynamicColorBuilder`）一律返回 null。
///
/// 任何失败（无插件、无壁纸、颜色未初始化、通道异常）都返回 null，由
/// ThemeController 回退到默认 seed——取不到时不改变现有表现。
///
/// 除启动时 [readSeed] 外，原生侧同时监听系统壁纸颜色变化并反向推送，
/// 订阅 [changes] 即可在壁纸切换后实时换肤。
///
/// [readSeed] 成功后结果在进程内记忆：页面切换、回前台等再次调用直接返回
/// 缓存，不再触发原生取色；壁纸变化由 [changes] 的反向推送更新缓存。
class SystemWallpaperColor {
  const SystemWallpaperColor._();

  static const MethodChannel _channel = MethodChannel('nexhub/wallpaper_color');

  static StreamController<Color?>? _changeController;

  /// 最近一次取到或推送来的壁纸主色；null 表示尚未成功取到。
  static Color? _latestSeed;

  /// 首次取色的在途请求；并发调用共享同一次原生调用。
  static Future<Color?>? _readFuture;

  /// 壁纸主色变化流（仅鸿蒙有事件源；其他平台为空流）。
  ///
  /// 首次访问时注册通道反向调用处理器；广播流只转发给当前订阅者。
  static Stream<Color?> get changes {
    if (!PlatformService.instance.isOHOS) return const Stream<Color?>.empty();
    if (_changeController == null) {
      final StreamController<Color?> controller =
          StreamController<Color?>.broadcast();
      _channel.setMethodCallHandler((MethodCall call) async {
        if (call.method != 'onWallpaperColorChanged') return null;
        final Object? args = call.arguments;
        if (args is List) {
          final Color? seed = fromRgba(args.cast<Object?>());
          if (seed != null) {
            _latestSeed = seed;
            controller.add(seed);
          }
        }
        return null;
      });
      _changeController = controller;
    }
    return _changeController!.stream;
  }

  /// 读取系统壁纸主色；不可用时返回 null。
  ///
  /// 首次成功后结果在进程内复用：构建新页面、回前台等再次调用不会走原生
  /// 通道。失败（null）不缓存，允许下次重试。
  static Future<Color?> readSeed() {
    if (!PlatformService.instance.isOHOS) return Future<Color?>.value(null);
    final Color? seed = _latestSeed;
    if (seed != null) return Future<Color?>.value(seed);
    return _readFuture ??= _readOnce().whenComplete(() => _readFuture = null);
  }

  static Future<Color?> _readOnce() async {
    try {
      final List<Object?>? rgba =
          await _channel.invokeMethod<List<Object?>>('getWallpaperColors');
      // 读取期间若有原生推送（壁纸刚变化），以推送值为准，避免旧值覆盖新值。
      return _latestSeed ??= fromRgba(rgba);
    } on Object {
      return _latestSeed;
    }
  }

  /// 将原生回传的 `[r, g, b, a]`（各 0-255）转为 [Color]。
  ///
  /// 组件缺失 / 越界 / 全透明均视为不可用。
  static Color? fromRgba(List<Object?>? rgba) {
    if (rgba == null || rgba.length < 4) return null;
    final int? r = _byte(rgba[0]);
    final int? g = _byte(rgba[1]);
    final int? b = _byte(rgba[2]);
    final int? a = _byte(rgba[3]);
    if (r == null || g == null || b == null || a == null || a == 0) {
      return null;
    }
    return Color.fromARGB(a, r, g, b);
  }

  static int? _byte(Object? value) {
    if (value is! int || value < 0 || value > 255) return null;
    return value;
  }
}
