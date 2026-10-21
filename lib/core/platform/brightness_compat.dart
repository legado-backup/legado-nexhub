import 'package:screen_brightness/screen_brightness.dart';

/// 屏幕亮度 API 兼容层。
///
/// 官方 `screen_brightness` 暴露 `setScreenBrightness` / `resetScreenBrightness` /
/// `onScreenBrightnessChanged`（系统级亮度）；鸿蒙适配 fork 改名为
/// `setApplicationScreenBrightness` / `resetApplicationScreenBrightness` /
/// `onApplicationScreenBrightnessChanged`（应用窗口级亮度）。
///
/// 两套依赖的方法名不同，但同一份应用代码需要在官方 SDK 与鸿蒙 SDK 下都能编译，
/// 因此这里用运行时探测：优先应用级（鸿蒙 fork），方法不存在时回退系统级（官方包）。
class BrightnessCompat {
  BrightnessCompat({ScreenBrightness? plugin})
    : _impl = plugin ?? ScreenBrightness();

  final dynamic _impl;

  /// 设置亮度（0..1）。鸿蒙走应用窗口级，其余平台回退系统级。
  Future<void> setApplicationScreenBrightness(double value) async {
    try {
      await (_impl as dynamic).setApplicationScreenBrightness(value);
    } on NoSuchMethodError {
      await (_impl as dynamic).setScreenBrightness(value);
    }
  }

  /// 恢复系统原亮度。
  Future<void> resetApplicationScreenBrightness() async {
    try {
      await (_impl as dynamic).resetApplicationScreenBrightness();
    } on NoSuchMethodError {
      await (_impl as dynamic).resetScreenBrightness();
    }
  }

  /// 当前系统亮度。
  Future<double> get current async =>
      (await (_impl as dynamic).current) as double;

  /// 亮度变化事件流。
  Stream<double> get onApplicationScreenBrightnessChanged {
    try {
      return (_impl as dynamic).onApplicationScreenBrightnessChanged
          as Stream<double>;
    } on NoSuchMethodError {
      return (_impl as dynamic).onScreenBrightnessChanged as Stream<double>;
    }
  }
}
