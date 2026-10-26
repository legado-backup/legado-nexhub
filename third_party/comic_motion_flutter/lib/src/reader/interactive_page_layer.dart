/// 互动阅读渲染层：聚焦一格、压暗其余、撕开揭示动效。
///
/// 可与宿主静态页叠加（`child == null` 纯覆盖层），也可自行包裹静态页
/// （传入 `child`）。点击入口有两种：
/// - 外层已有透明手势层（如阅读器）：宿主用 `GlobalKey` 调
///   [InteractivePageLayerState.handleTap]；
/// - 独立演示：`interactive: true` 由本组件自己接单击。
///
/// 动画纪律：静态页（`child`）不参与逐帧重建；聚焦/撕开/呼吸由
/// `AnimatedBuilder` 与 `CustomPainter(repaint:)` 驱动。减弱动态下不构造
/// GIF 解码，仅显示首帧静帧与聚焦轮廓；[MotionPowerAware] 聚合生命周期、
/// 视口与 App 策略，抑制时停呼吸并暂停 GIF。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../motion_gif_view.dart';
import '../power_aware.dart';
import 'panel_focus.dart';
import 'panel_layout.dart';
import 'panel_manifest.dart';

const Duration _kUnfocusDuration = Duration(milliseconds: 280);
const Duration _kBreathDuration = Duration(milliseconds: 2400);
const Cubic _kFocusCurve = Cubic(0.2, 0, 0, 1);

/// 页面动效模式（v1.6「需要动效时才展示动效」）。
enum PageMotionMode {
  /// 现状行为：聚焦期间呼吸光晕持续循环。
  always,

  /// 触发式：聚焦入场播一轮呼吸（约 2.4s）后静息为常亮轮廓，失焦再聚焦
  /// 重播。GIF 本体的「播完归静」由引擎 v1.6 `EffectConfig.holdSec` 在
  /// 容器层承担；陀螺仪/触摸视差（ParallaxGyroView）属用户输入驱动，
  /// 不受本开关影响。
  onDemand,
}

/// 分格聚焦互动层。
class InteractivePageLayer extends StatefulWidget {
  const InteractivePageLayer({
    super.key,
    this.child,
    this.fit = BoxFit.contain,
    this.imageSize,
    this.quarterTurns = 0,
    this.manifest,
    this.gifBytes,
    this.firstFramePng,
    this.panelClips = const <String, Uint8List>{},
    this.controller,
    this.interactive = false,
    this.hoverToFocus = false,
    this.gazeStream,
    this.respectReducedMotion = true,
    this.pauseWhenNotVisible = true,
    this.enableMotion,
    this.motionMode = PageMotionMode.always,
    this.focusDuration = const Duration(milliseconds: 220),
    this.revealDuration = const Duration(milliseconds: 420),
    this.onFocusChanged,
  });

  /// T0 隐式整页格的 id。
  static const String pagePanelId = '__page__';

  static const Key overlayKey = ValueKey<String>('comic-interactive-overlay');
  static const Key dimKey = ValueKey<String>('comic-interactive-dim');
  static const Key clipKey = ValueKey<String>('comic-interactive-clip');

  /// 可选静态页；为 null 时本组件只画覆盖层（宿主已有静态页）。
  final Widget? child;

  /// 页面在可用区域内如何适配；T0 未提供 [imageSize] 时页面铺满可用区域。
  final BoxFit fit;

  /// 源图尺寸。T1（[manifest] 非空）必填。
  final Size? imageSize;

  /// 页面顺时针旋转的 90° 份数（0..3）。
  final int quarterTurns;

  /// 分格清单；null = T0 整页模式。
  final PanelManifest? manifest;

  /// 整页动效 GIF 字节。
  final Uint8List? gifBytes;

  /// 首帧静帧（占位 / 减弱动态）。
  final Uint8List? firstFramePng;

  /// T2 格级素材：panelId → 字节；存在时优先于整页 GIF。
  final Map<String, Uint8List> panelClips;

  /// 外部聚焦控制器；未提供时内部创建并随组件销毁。
  final PanelFocusController? controller;

  /// 自接单击（外层无手势层时用）；外层有透明手势层时用
  /// [InteractivePageLayerState.handleTap]。
  final bool interactive;

  /// 鼠标悬停即聚焦（不消费点击，移出不强制失焦）。
  final bool hoverToFocus;

  /// 归一化页面坐标（[0,1]²）的注视流；内部映射到分格并做停留去抖。
  final Stream<Offset>? gazeStream;

  /// 系统减弱动态时静帧（默认 true）。
  final bool respectReducedMotion;

  /// 滚出视口自动暂停（W4）。
  final bool pauseWhenNotVisible;

  /// App 动效策略钩子（W4）。
  final bool Function()? enableMotion;

  /// 页面动效模式（[PageMotionMode]）。默认 [PageMotionMode.always] 与
  /// 旧版行为逐帧一致；[PageMotionMode.onDemand] 下呼吸光晕只在聚焦入场
  /// 播一轮，之后静息为常亮轮廓。
  final PageMotionMode motionMode;

  /// 聚焦过渡时长。
  final Duration focusDuration;

  /// 撕开揭示时长。
  final Duration revealDuration;

  /// 逻辑焦点变化回调（包括失焦为 null）。
  final void Function(String? panelId)? onFocusChanged;

  @override
  State<InteractivePageLayer> createState() => InteractivePageLayerState();
}

class InteractivePageLayerState extends State<InteractivePageLayer>
    with
        MotionPowerAware<InteractivePageLayer>,
        TickerProviderStateMixin<InteractivePageLayer> {
  final PanelFocusController _internal = PanelFocusController();
  PanelFocusController get _controller => widget.controller ?? _internal;

  late final AnimationController _focusCtrl;
  late final AnimationController _tearCtrl;
  late final AnimationController _breathCtrl;
  late final CurvedAnimation _focusEase;

  String? _displayId;
  PanelLayout? _lastLayout;
  bool _reducedMotion = false;
  String? _lastNotifiedFocus;
  String? _hoverId;
  Offset? _pendingGaze;
  StreamSubscription<Offset>? _gazeSub;

  @override
  bool Function()? get enableMotion => widget.enableMotion;

  @override
  bool get pauseWhenNotVisible => widget.pauseWhenNotVisible;

  @override
  void initState() {
    super.initState();
    _focusCtrl = AnimationController(
      vsync: this,
      duration: widget.focusDuration,
      reverseDuration: _kUnfocusDuration,
    );
    _focusEase = CurvedAnimation(parent: _focusCtrl, curve: _kFocusCurve);
    _tearCtrl = AnimationController(
      vsync: this,
      duration: widget.revealDuration,
    );
    _breathCtrl = AnimationController(vsync: this, duration: _kBreathDuration);
    _breathCtrl.addStatusListener(_handleBreathStatus);
    _focusCtrl.addStatusListener(_handleFocusAnimationStatus);
    _controller.addListener(_handleFocusChange);
    _lastNotifiedFocus = _controller.primaryId;
    _displayId = _lastNotifiedFocus;
    if (_displayId != null) {
      _focusCtrl.value = 1;
      _tearCtrl.value = 1;
    }
    _subscribeGaze();
    motionPowerInit();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _applyReducedMotion(_computeReducedMotion());
  }

  @override
  void didUpdateWidget(covariant InteractivePageLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _internal).removeListener(_handleFocusChange);
      _controller.addListener(_handleFocusChange);
      _syncFromController();
    }
    if (oldWidget.gazeStream != widget.gazeStream) {
      _gazeSub?.cancel();
      _gazeSub = null;
      _subscribeGaze();
    }
    if (oldWidget.focusDuration != widget.focusDuration) {
      _focusCtrl.duration = widget.focusDuration;
    }
    if (oldWidget.revealDuration != widget.revealDuration) {
      _tearCtrl.duration = widget.revealDuration;
    }
    if (oldWidget.respectReducedMotion != widget.respectReducedMotion) {
      _applyReducedMotion(_computeReducedMotion());
    }
    if (oldWidget.motionMode != widget.motionMode) {
      // didUpdateWidget 之后必跟一次 build，无需显式 setState 翻转光晕。
      if (widget.motionMode == PageMotionMode.onDemand) {
        _breathCtrl.stop();
      } else {
        _startBreath();
      }
    }
    if (oldWidget.pauseWhenNotVisible != widget.pauseWhenNotVisible ||
        oldWidget.enableMotion != widget.enableMotion) {
      reassessMotion();
    }
    final String? shown = _displayId;
    if (oldWidget.manifest != widget.manifest &&
        shown != null &&
        _specFor(shown) == null) {
      _controller.unfocus();
    }
  }

  @override
  void dispose() {
    motionPowerDispose();
    (widget.controller ?? _internal).removeListener(_handleFocusChange);
    _internal.dispose();
    _gazeSub?.cancel();
    _focusEase.dispose();
    _breathCtrl.dispose();
    _tearCtrl.dispose();
    _focusCtrl.dispose();
    super.dispose();
  }

  // ---- 公共 API ----

  /// 当前逻辑聚焦格（失焦为 null）。
  String? get focusedId => _controller.primaryId;

  /// 呼吸光晕是否在播（onDemand 模式一轮播完即 false）。
  bool get breathing => _breathCtrl.isAnimating;

  /// 全局坐标点击：换算到层内坐标并走命中/切换；消费本次点击返回 true。
  bool handleTap(Offset globalPosition) {
    final PanelLayout? layout = _lastLayout;
    final RenderObject? ro = context.findRenderObject();
    if (layout == null || ro is! RenderBox || !ro.hasSize) return false;
    return _controller.tapAt(layout, ro.globalToLocal(globalPosition));
  }

  /// 聚焦指定格（T0 用 [InteractivePageLayer.pagePanelId]）；id 无效返回 false。
  bool focusPanel(String id) {
    if (_specFor(id) == null) return false;
    _controller.focus(id);
    return true;
  }

  /// 清除焦点。
  void unfocus() => _controller.unfocus();

  // ---- 焦点与动画 ----

  void _handleFocusChange() {
    final String? primary = _controller.primaryId;
    final bool notify = primary != _lastNotifiedFocus;
    if (primary == null) {
      if (_displayId != null) _beginUnfocus();
    } else if (primary != _displayId) {
      _beginFocus(primary);
    }
    if (notify) {
      _lastNotifiedFocus = primary;
      widget.onFocusChanged?.call(primary);
    }
  }

  void _beginFocus(String id) {
    final PanelSpec? spec = _specFor(id);
    if (spec == null) return;
    setState(() => _displayId = id);
    if (_reducedMotion) {
      _breathCtrl.stop();
      _focusCtrl.value = 1;
      _tearCtrl.value = 1;
      return;
    }
    _focusCtrl.forward();
    if (spec.reveal == PanelReveal.none || widget.revealDuration == Duration.zero) {
      _tearCtrl.value = 1;
    } else {
      _tearCtrl.forward(from: 0);
    }
    _startBreath();
  }

  void _beginUnfocus() {
    _breathCtrl.stop();
    if (_reducedMotion || !motionActive) {
      _focusCtrl.value = 0;
      _tearCtrl.value = 0;
      setState(() => _displayId = null);
      return;
    }
    _focusCtrl.reverse();
  }

  void _handleFocusAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    if (_controller.primaryId != null || _displayId == null) return;
    _tearCtrl.value = 0;
    setState(() => _displayId = null);
  }

  void _startBreath() {
    if (_reducedMotion || !motionActive || _displayId == null) return;
    if (widget.motionMode == PageMotionMode.onDemand) {
      // 触发式（v1.6）：入场播一轮（去程+回程）即静息，见 _handleBreathStatus。
      _breathCtrl.forward(from: 0);
      return;
    }
    if (!_breathCtrl.isAnimating) _breathCtrl.repeat(reverse: true);
  }

  void _handleBreathStatus(AnimationStatus status) {
    if (widget.motionMode != PageMotionMode.onDemand) return;
    if (status == AnimationStatus.completed) {
      _breathCtrl.reverse();
    } else if (status == AnimationStatus.dismissed && mounted) {
      // 一轮播完：光晕回静息态（pulse 恒 1.0，不再脉动）。
      setState(() {});
    }
  }

  @override
  void onMotionSuppressed() {
    _breathCtrl.stop();
    if (mounted) setState(() {});
  }

  @override
  void onMotionRestored() {
    _startBreath();
    if (mounted) setState(() {});
  }

  bool _computeReducedMotion() =>
      widget.respectReducedMotion &&
      (MediaQuery.maybeOf(context)?.disableAnimations ?? false);

  void _applyReducedMotion(bool reduced) {
    if (reduced == _reducedMotion) return;
    _reducedMotion = reduced;
    if (_displayId == null) return;
    _tearCtrl.value = 1;
    if (reduced) {
      _breathCtrl.stop();
      _focusCtrl.value = 1;
    } else {
      _startBreath();
    }
  }

  void _syncFromController() {
    final String? primary = _controller.primaryId;
    _displayId = primary;
    _lastNotifiedFocus = primary;
    _focusCtrl.value = primary == null ? 0 : 1;
    _tearCtrl.value = primary == null ? 0 : 1;
    if (primary != null) _startBreath();
  }

  PanelSpec? _specFor(String id) {
    final PanelManifest? manifest = widget.manifest;
    if (manifest == null) {
      return id == InteractivePageLayer.pagePanelId
          ? const PanelSpec(
              id: InteractivePageLayer.pagePanelId,
              rect: Rect.fromLTRB(0, 0, 1, 1),
            )
          : null;
    }
    for (final PanelSpec panel in manifest.panels) {
      if (panel.id == id) return panel;
    }
    return null;
  }

  // ---- 注视 ----

  void _subscribeGaze() {
    final Stream<Offset>? stream = widget.gazeStream;
    if (stream == null) return;
    _gazeSub = stream.listen(_onGaze);
  }

  void _onGaze(Offset normalized) {
    final PanelLayout? layout = _lastLayout;
    if (layout == null) {
      _pendingGaze = normalized;
      return;
    }
    _applyGaze(layout, normalized);
  }

  void _applyGaze(PanelLayout layout, Offset normalized) {
    final Rect page = layout.pageRect;
    final Offset local = Offset(
      page.left + normalized.dx * page.width,
      page.top + normalized.dy * page.height,
    );
    _controller.updateGaze(layout.hitTest(local));
  }

  void _consumePendingGaze(PanelLayout layout) {
    final Offset? pending = _pendingGaze;
    if (pending == null) return;
    _pendingGaze = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyGaze(layout, pending);
    });
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    Widget content = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Rect available = Offset.zero & constraints.biggest;
        final PanelLayout layout = _resolveLayout(available);
        _lastLayout = layout;
        _consumePendingGaze(layout);

        final String? shown = _displayId;
        final PanelSpec? spec = shown == null ? null : _specFor(shown);
        final Rect? panelRect = spec == null ? null : layout.panelRects[spec.id];

        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (widget.child != null) widget.child!,
            if (spec != null && panelRect != null)
              _buildOverlay(spec: spec, layout: layout, panelRect: panelRect),
            if (widget.hoverToFocus) _buildHoverLayer(layout),
            if (widget.interactive) _buildTapLayer(layout),
          ],
        );
      },
    );
    if (widget.pauseWhenNotVisible) {
      content = NotificationListener<ScrollNotification>(
        onNotification: onMotionScrollNotification,
        child: content,
      );
    }
    return content;
  }

  PanelLayout _resolveLayout(Rect available) {
    final PanelManifest? manifest = widget.manifest;
    final Size? imageSize = widget.imageSize;
    if (manifest == null) {
      if (imageSize == null) {
        return PanelLayout(
          availableRect: available,
          pageRect: available,
          panelRects: <String, Rect>{
            InteractivePageLayer.pagePanelId: available,
          },
        );
      }
      return PanelLayout.resolve(
        availableRect: available,
        imageSize: imageSize,
        panels: const <PanelSpec>[
          PanelSpec(
            id: InteractivePageLayer.pagePanelId,
            rect: Rect.fromLTRB(0, 0, 1, 1),
          ),
        ],
        fit: widget.fit,
        quarterTurns: widget.quarterTurns,
      );
    }
    assert(imageSize != null, 'InteractivePageLayer: T1 清单需要 imageSize');
    return PanelLayout.resolve(
      availableRect: available,
      imageSize: imageSize ?? available.size,
      panels: manifest.panels,
      fit: widget.fit,
      quarterTurns: widget.quarterTurns,
    );
  }

  Widget _buildOverlay({
    required PanelSpec spec,
    required PanelLayout layout,
    required Rect panelRect,
  }) {
    final Uint8List? clipBytes = widget.panelClips[spec.id];
    final Widget media = _buildMedia(
      spec: spec,
      pageRect: layout.pageRect,
      panelRect: panelRect,
      clipBytes: clipBytes,
    );
    return Positioned.fill(
      key: InteractivePageLayer.overlayKey,
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            CustomPaint(
              key: InteractivePageLayer.dimKey,
              painter: _ScrimPainter(
                panelRect: panelRect,
                dim: spec.dim,
                focus: _focusEase,
              ),
            ),
            Positioned.fromRect(
              key: InteractivePageLayer.clipKey,
              rect: panelRect,
              child: AnimatedBuilder(
                animation: Listenable.merge(<Listenable>[_focusEase, _tearCtrl]),
                builder: (BuildContext context, Widget? child) {
                  Widget result = Transform.scale(
                    scale: 1 + (spec.scale - 1) * _focusEase.value,
                    alignment: Alignment.center,
                    child: child,
                  );
                  switch (spec.reveal) {
                    case PanelReveal.tear:
                      result = ClipPath(
                        clipper: _TearClipper(_tearCtrl.value),
                        child: result,
                      );
                    case PanelReveal.fade:
                      result = Opacity(
                        opacity: _tearCtrl.value.clamp(0.0, 1.0),
                        child: result,
                      );
                    case PanelReveal.none:
                      break;
                  }
                  return result;
                },
                child: media,
              ),
            ),
            if (spec.reveal == PanelReveal.tear)
              CustomPaint(
                painter: _TearEdgePainter(
                  animation: _tearCtrl,
                  panelRect: panelRect,
                ),
              ),
            CustomPaint(
              painter: _GlowPainter(
                panelRect: panelRect,
                glow: spec.glow,
                focus: _focusEase,
                breath: _breathCtrl,
                breathing: _breathCtrl.isAnimating,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMedia({
    required PanelSpec spec,
    required Rect pageRect,
    required Rect panelRect,
    Uint8List? clipBytes,
  }) {
    if (!_reducedMotion && clipBytes != null) {
      return MotionGifView(
        gifBytes: clipBytes,
        playing: motionActive,
        loop: spec.clip?.loop ?? true,
        fit: BoxFit.fill,
        pauseWhenNotVisible: widget.pauseWhenNotVisible,
        enableMotion: widget.enableMotion,
      );
    }

    final Widget pageMedia;
    if (!_reducedMotion && widget.gifBytes != null) {
      pageMedia = MotionGifView(
        gifBytes: widget.gifBytes!,
        firstFramePng: widget.firstFramePng,
        playing: motionActive,
        fit: BoxFit.fill,
        pauseWhenNotVisible: widget.pauseWhenNotVisible,
        enableMotion: widget.enableMotion,
      );
    } else if (widget.firstFramePng != null) {
      pageMedia = Image.memory(
        widget.firstFramePng!,
        fit: BoxFit.fill,
        gaplessPlayback: true,
      );
    } else {
      return const SizedBox.expand();
    }

    if (panelRect == pageRect) return pageMedia;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned(
          left: pageRect.left - panelRect.left,
          top: pageRect.top - panelRect.top,
          width: pageRect.width,
          height: pageRect.height,
          child: pageMedia,
        ),
      ],
    );
  }

  Widget _buildHoverLayer(PanelLayout layout) {
    return Positioned.fill(
      child: MouseRegion(
        opaque: false,
        onHover: (PointerHoverEvent event) {
          final String? hit = layout.hitTest(event.localPosition);
          if (hit == _hoverId) return;
          _hoverId = hit;
          if (hit != null) _controller.focus(hit);
        },
        child: const SizedBox.expand(),
      ),
    );
  }

  Widget _buildTapLayer(PanelLayout layout) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: (TapUpDetails details) =>
            _controller.tapAt(layout, details.localPosition),
      ),
    );
  }
}

class _ScrimPainter extends CustomPainter {
  _ScrimPainter({
    required this.panelRect,
    required this.dim,
    required this.focus,
  }) : super(repaint: focus);

  final Rect panelRect;
  final double dim;
  final Animation<double> focus;

  @override
  void paint(Canvas canvas, Size size) {
    final double f = focus.value.clamp(0.0, 1.0);
    if (dim <= 0 || f <= 0) return;
    final Path outer = Path()..addRect(Offset.zero & size);
    final Path inner = Path()..addRect(panelRect);
    canvas.drawPath(
      Path.combine(PathOperation.difference, outer, inner),
      Paint()..color = const Color(0xFF000000).withValues(alpha: dim * f),
    );
  }

  @override
  bool shouldRepaint(covariant _ScrimPainter oldDelegate) =>
      oldDelegate.panelRect != panelRect || oldDelegate.dim != dim;
}

class _GlowPainter extends CustomPainter {
  _GlowPainter({
    required this.panelRect,
    required this.glow,
    required this.focus,
    required this.breath,
    required this.breathing,
  }) : super(repaint: Listenable.merge(<Listenable>[focus, breath]));

  final Rect panelRect;
  final double glow;
  final Animation<double> focus;
  final Animation<double> breath;
  final bool breathing;

  @override
  void paint(Canvas canvas, Size size) {
    final double f = focus.value.clamp(0.0, 1.0);
    if (glow <= 0 || f <= 0) return;
    final double pulse = breathing ? 0.72 + 0.28 * breath.value : 1.0;
    final double alpha = (glow * f * pulse).clamp(0.0, 1.0);
    final Rect rect = panelRect.deflate(0.8);
    if (rect.isEmpty) return;
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xFFFFF3C4).withValues(alpha: alpha * 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = const Color(0xFFFFF8DC).withValues(alpha: alpha),
    );
  }

  @override
  bool shouldRepaint(covariant _GlowPainter oldDelegate) =>
      oldDelegate.panelRect != panelRect ||
      oldDelegate.glow != glow ||
      oldDelegate.breathing != breathing;
}

class _TearEdgePainter extends CustomPainter {
  _TearEdgePainter({required this.animation, required this.panelRect})
      : super(repaint: animation);

  final Animation<double> animation;
  final Rect panelRect;

  @override
  void paint(Canvas canvas, Size size) {
    final double p = animation.value;
    if (p <= 0 || p >= 1) return;
    final Path edge = _tearEdge(panelRect, p);
    canvas.drawPath(
      edge,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(covariant _TearEdgePainter oldDelegate) =>
      oldDelegate.panelRect != panelRect;
}

class _TearClipper extends CustomClipper<Path> {
  const _TearClipper(this.progress);

  final double progress;

  @override
  Path getClip(Size size) {
    final double p = progress.clamp(0.0, 1.0);
    if (p <= 0) return Path();
    if (p >= 1) return Path()..addRect(Offset.zero & size);

    final double edge = size.width * p;
    final Path path = Path()
      ..moveTo(0, 0)
      ..lineTo(edge, 0);
    bool outward = true;
    double y = 0;
    while (y < size.height) {
      y = (y + 16).clamp(0.0, size.height);
      final double x = (edge + (outward ? 7.0 : -7.0)).clamp(0.0, size.width);
      path.lineTo(x, y);
      outward = !outward;
    }
    path
      ..lineTo(0, size.height)
      ..close();
    return path;
  }

  @override
  bool shouldReclip(covariant _TearClipper oldClipper) =>
      oldClipper.progress != progress;
}

Path _tearEdge(Rect panelRect, double progress) {
  final double edge = panelRect.left + panelRect.width * progress;
  final Path path = Path()..moveTo(edge, panelRect.top);
  bool outward = true;
  double y = panelRect.top;
  while (y < panelRect.bottom) {
    y = (y + 16).clamp(panelRect.top, panelRect.bottom);
    final double x = (edge + (outward ? 7.0 : -7.0))
        .clamp(panelRect.left, panelRect.right);
    path.lineTo(x, y);
    outward = !outward;
  }
  return path;
}
