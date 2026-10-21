import 'package:material_ui/material_ui.dart';

/// 应用统一页面路由。
///
/// 不覆盖转场时长与动画，交由 Flutter 按当前平台取系统默认：
/// Android 预测性返回 / Zoom，iOS / macOS Cupertino 侧滑，桌面与鸿蒙 Zoom。
/// 仅保留 [MaterialPageRoute] 的默认参数，作为全局页面跳转的统一入口，
/// 便于后续在单点调整路由行为。
///
/// 仅作用于**页面路由**（[Navigator.push] 的匿名路由）。对话框走 [DialogRoute]、
/// 底部抽屉走 [ModalBottomSheetRoute]，二者各自保留动画，不受此影响。
class AppPageRoute<T> extends MaterialPageRoute<T> {
  AppPageRoute({
    required super.builder,
    super.settings,
    super.maintainState = true,
    super.fullscreenDialog = false,
    super.allowSnapshotting = true,
  });
}
