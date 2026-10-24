import 'package:material_ui/material_ui.dart';

/// 全局 Navigator 入口（供无 BuildContext 的深链 / 接续跳转使用）。
///
/// 在 [MaterialApp.navigatorKey] 注册；[key] 在 MaterialApp 挂载后可用。
class AppNavigator {
  AppNavigator._();

  static final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();

  static NavigatorState? get navigator => key.currentState;
}
