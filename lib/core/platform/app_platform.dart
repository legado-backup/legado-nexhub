/// 平台判定抽象（规格 §4）。
///
/// 全仓平台判断统一收口到这里，禁止散落的 `Platform.isXxx` 组合：
/// - 能力轴（触屏交互、文件选择、通知等）：[isMobile]（含鸿蒙）；
/// - 形态轴（窗口尺寸行为、桌面全屏等）：[isDesktopForm]（鸿蒙 PC 后续接
///   deviceType 再补，当前与桌面一致）。
///
/// 背景：鸿蒙 Flutter 的 `Platform.operatingSystem` 返回 `'ohos'`，
/// 既不是 Android 也不是 Linux，任何按平台分支的旧代码默认会走到
/// 「else / 桌面」分支，因此新增判定时务必二选一挂到能力轴或形态轴。
library;

import 'dart:io' show Platform;

/// 平台判定工具（静态方法，不可实例化）。
abstract final class AppPlatform {
  /// 是否鸿蒙（OpenHarmony / HarmonyOS NEXT）。
  static bool get isOhos => Platform.operatingSystem == 'ohos';

  /// 能力轴：触屏 / 移动系交互（相册、WebView、震动、移动端手势等）。
  ///
  /// 鸿蒙手机与 Android / iOS 同属移动能力集。
  static bool get isMobile => isOhos || Platform.isAndroid || Platform.isIOS;

  /// 形态轴：传统桌面窗口（窗口管理、滚动条、悬浮窗等）。
  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// 形态轴（含未来鸿蒙 PC）：当前与 [isDesktop] 一致，
  /// 鸿蒙 PC 判定接入后改为 `isDesktop || (isOhos && isPcFormFactor)`。
  static bool get isDesktopForm => isDesktop;
}
