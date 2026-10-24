import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';

import '../platform/platform_service.dart';
import '../settings/general_settings.dart';

/// 鸿蒙：轻点系统状态栏回到当前页面顶部。
///
/// 鸿蒙引擎把 `usual.event.CLICK_STATUSBAR` 转成 `handleScrollToTop`，再分发给
/// [WidgetsBindingObserver.handleStatusBarTap]。Material 的 [Scaffold] 只处理
/// 挂了 primary 控制器的滚动视图，这里在应用根统一兜底：记住最后一次顶层纵向
/// 滚动位置，点按状态栏时动画回顶部。
///
/// 只跟踪 `depth == 0` 的纵向滚动（页面主列表），横向轮播等嵌套滚动不参与；
/// 点击时校验所在路由仍在栈顶且滚动视图可命中，避免误滚被覆盖的页面。
class StatusBarTapToTop extends StatefulWidget {
  final Widget child;

  const StatusBarTapToTop({super.key, required this.child});

  @override
  State<StatusBarTapToTop> createState() => _StatusBarTapToTopState();
}

class _StatusBarTapToTopState extends State<StatusBarTapToTop>
    with WidgetsBindingObserver {
  ScrollPosition? _position;
  BuildContext? _context;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    final ScrollMetrics metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    _position = metrics is ScrollPosition ? metrics : null;
    _context = notification.context;
    return false;
  }

  @override
  void handleStatusBarTap() {
    if (!PlatformService.instance.isOHOS) return;
    if (!GeneralSettingsStore.instance.statusBarTapToTop) return;
    final ScrollPosition? position = _position;
    final BuildContext? scrollContext = _context;
    if (position == null ||
        scrollContext == null ||
        !scrollContext.mounted ||
        !position.hasPixels ||
        !position.hasContentDimensions ||
        position.pixels <= position.minScrollExtent ||
        ModalRoute.of(scrollContext)?.isCurrent != true ||
        !_isHitTestable(scrollContext, position)) {
      return;
    }
    position.animateTo(
      position.minScrollExtent,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  /// 滚动视图在自身范围内可命中（前景页面 / 未被弹层遮挡）。
  bool _isHitTestable(BuildContext context, ScrollPosition position) {
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;
    final Rect rect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    if (rect.isEmpty) return false;
    final int viewId = View.of(context).viewId;
    final HitTestResult result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, rect.center, viewId);
    return result.path.any((HitTestEntry entry) => entry.target == renderObject);
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: widget.child,
    );
  }
}
