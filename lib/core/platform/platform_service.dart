/// 平台能力抽象层（规格）。
///
/// 所有平台相关判定（桌面/移动/Web/HarmonyOS NEXT）与未来平台分支统一收敛于此，
/// feature 与 core 业务代码不得直接写 `Platform.isXxx` / `defaultTargetPlatform` 分支。
/// 新增平台（如 HarmonyOS NEXT / Flutter-OH）只改本文件与 `pubspec.yaml` 的
/// `dependency_overrides`，无需散落到各业务模块。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 应用运行平台枚举。
enum AppPlatform {
  android,
  ios,
  windows,
  macos,
  linux,
  web,
  ohos,
}

/// 平台能力查询（单例）。
///
/// 所有判定均以 [kIsWeb] 优先守卫，避免 Web 平台访问 `dart:io` 的 [Platform] 抛错。
class PlatformService {
  const PlatformService._();

  /// 单例。
  static const PlatformService instance = PlatformService._();

  /// 是否为 Web（[Platform] 不可用）。
  bool get isWeb => kIsWeb;

  /// 是否为 Windows 桌面。
  bool get isWindows => !kIsWeb && Platform.isWindows;

  /// 是否为 Android。
  bool get isAndroid => !kIsWeb && Platform.isAndroid;

  /// 是否为 iOS。
  bool get isIOS => !kIsWeb && Platform.isIOS;

  /// 是否为 macOS。
  bool get isMacOS => !kIsWeb && Platform.isMacOS;

  /// 是否为 Linux。
  bool get isLinux => !kIsWeb && Platform.isLinux;

  /// 是否为 HarmonyOS NEXT（Flutter-OH）。
  ///
  /// 鸿蒙 Flutter fork 的 `Platform.operatingSystem` 返回 `'ohos'`。
  /// Web 平台访问 `Platform` 会抛错，故以 [kIsWeb] 守卫。
  bool get isOHOS => !kIsWeb && Platform.operatingSystem == 'ohos';

  /// 能力轴：触屏 / 移动系交互（相册、WebView、震动、移动端手势等）。
  ///
  /// 鸿蒙手机与 Android / iOS 同属移动能力集（规格 §4）。
  bool get isMobile => isAndroid || isIOS || isOHOS;

  /// 当前平台枚举（用于 UI 自适应与路由决策）。
  AppPlatform get current {
    if (isWeb) return AppPlatform.web;
    if (isOHOS) return AppPlatform.ohos;
    if (isWindows) return AppPlatform.windows;
    if (isAndroid) return AppPlatform.android;
    if (isIOS) return AppPlatform.ios;
    if (isMacOS) return AppPlatform.macos;
    return AppPlatform.linux;
  }

  /// 形态轴：传统桌面窗口（窗口管理 / 滚动条 / 悬浮窗）。
  bool get isDesktop => isWindows || isMacOS || isLinux;

  /// 形态轴（含未来鸿蒙 PC）：当前与 [isDesktop] 一致，
  /// 鸿蒙 PC 判定（deviceType）接入后在此扩展。
  bool get isDesktopForm => isDesktop;
}
