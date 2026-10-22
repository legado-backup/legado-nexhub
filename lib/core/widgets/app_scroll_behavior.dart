import 'package:material_ui/material_ui.dart';

import '../platform/platform_service.dart';

/// 应用级滚动行为：桌面形态（含鸿蒙 PC）显示纵向滚动条、去掉 overscroll 回弹。
///
/// patched material 的 MaterialScrollBehavior 对 TargetPlatform.ohos 固定返回
/// 「无滚动条 + Stretching overscroll」，与屏幕形态无关；鸿蒙 PC 需要 Windows
/// 同款的滚轮 / 滚动条体验，故在应用层按 isDesktopForm 覆写。手机端仍走
/// super，保留拉伸反馈。
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (!PlatformService.instance.isDesktopForm ||
        axisDirectionToAxis(details.direction) != Axis.vertical) {
      return child;
    }
    return Scrollbar(controller: details.controller, child: child);
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (PlatformService.instance.isDesktopForm) return child;
    return super.buildOverscrollIndicator(context, child, details);
  }
}
