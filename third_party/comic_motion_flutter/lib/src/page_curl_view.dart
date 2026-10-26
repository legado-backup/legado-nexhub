/// PageCurlView：仿真卷页翻页视图（第五轮 W1）。
///
/// 移植 `realtime/index.html` 的 Canvas 参考实现，对齐鸿蒙翻页手感的五种
/// 行为：
/// - **卷页曲率**：当前页按纵向条带绘制，越靠近折轴压缩越强
///   （`cos(dist·π/2·(0.65+0.35·curve))` 圆柱投影近似），拖拽速度决定
///   页面软硬（curve ∈ [0,1]）；
/// - **拖拽跟手**：进度 = 水平位移 / 视宽，钳制 [0,1]；
/// - **松手回弹过冲**：越过阈值（位移 > [PageCurlView.commitThreshold] 或
///   速度足够）走 OVERSHOOT 缓动（峰值 1.045 后收回），否则原路弹回；
/// - **双层光影**：卷轴高光 + 纸背透色 + 折轴落影 + 页缘阴影；
/// - **idle 呼吸微动**：无操作时整页极缓浮沉（±0.4%，6s 周期）。
///
/// 页面内容抓取（第五轮确认方案）：平时显示原生 widget；拖拽 / 点击翻页
/// **开始的瞬间**经 RepaintBoundary 按需截屏 front/back 两页 `ui.Image`，
/// 绘制全程用快照做条带卷曲。起步约 1 帧截屏延迟（观感无感，期间底层原生
/// widget 兜底显示）；截屏失败时该次翻页退化为瞬时切页（不卡死、不白屏）。
///
/// 性能：翻页与呼吸全部走 `CustomPainter` + repaint listenable 局部重绘，
/// 手势帧不重建 widget 树、不重调 builder（页面子树按页码缓存）；条带数
/// [PageCurlView.curlStrips] 可调（默认 28）。
///
/// 钩子：[PageCurlView.onPageTurnStart] / [onPageTurnEnd]——App 自接音效 /
/// 触觉，本包不引 audio / vibration 依赖。系统「减弱动态」开启时回退为
/// 简单平移淡入淡出（不截屏、无卷曲、无呼吸）。
///
/// 限制：快照是页面位图，覆盖在原生 widget 之上；页面内的嵌套手势
/// （选中、内滚）在翻页视图里不响应——阅读页本身是静态内容，属预期。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 翻页结束回调：[committed] = 是否真正翻页。
typedef PageTurnEndCallback = void Function(int from, int to, bool committed);

/// 仿真卷页翻页视图。用法见 README「PageCurlView」。
class PageCurlView extends StatefulWidget {
  const PageCurlView({
    super.key,
    required this.pageCount,
    required this.frontBuilder,
    required this.backBuilder,
    this.initialPage = 0,
    this.turnDuration = const Duration(milliseconds: 520),
    this.commitThreshold = 0.32,
    this.commitVelocity = 0.55,
    this.curlStrips = 28,
    this.idleBreath = true,
    this.respectReducedMotion = true,
    this.enableTapTurn = true,
    this.onPageTurnStart,
    this.onPageTurnEnd,
  })  : assert(pageCount >= 1, 'pageCount must be >= 1'),
        assert(
            initialPage >= 0 && initialPage < pageCount,
            'initialPage must be in [0, pageCount)'),
        assert(turnDuration > Duration.zero, 'turnDuration must be > 0'),
        assert(
            commitThreshold > 0 && commitThreshold < 1,
            'commitThreshold must be in (0, 1)'),
        assert(curlStrips >= 4 && curlStrips <= 128,
            'curlStrips must be in [4, 128]');

  /// 总页数（≥1）。
  final int pageCount;

  /// 第 [pageIndex] 页的内容。翻页过程中 front = 被卷起的当前页。
  final Widget Function(BuildContext context, int pageIndex) frontBuilder;

  /// 第 [pageIndex] 页的内容。翻页过程中 back = 底下露出的目标页。
  final Widget Function(BuildContext context, int pageIndex) backBuilder;

  /// 初始页码。
  final int initialPage;

  /// 翻页动画时长（点击翻页与松手补间共用；鸿蒙手感约 520ms）。
  final Duration turnDuration;

  /// 松手翻页的位移阈值（进度比例，默认 0.32）。
  final double commitThreshold;

  /// 松手翻页的速度阈值（进度/秒，默认 0.55）。
  final double commitVelocity;

  /// 卷页条带数（越多曲率越平滑，帧成本线性上升；默认 28）。
  final int curlStrips;

  /// idle 呼吸微动开关（±0.4%、6s 周期；默认开）。
  final bool idleBreath;

  /// 系统「减弱动态」开启时回退平移淡入淡出（true，默认）。
  final bool respectReducedMotion;

  /// 点击左右半屏翻页（默认开）。
  final bool enableTapTurn;

  /// 翻页开始（拖拽起步或点击翻页确定目标后触发）。App 自接音效/触觉。
  final void Function(int from, int to)? onPageTurnStart;

  /// 翻页结束（补间完成；committed = 是否真正翻页）。
  final PageTurnEndCallback? onPageTurnEnd;

  /// 测试探针：当前翻页进度（拖拽 / 补间中的 [0,1]，idle 为 0）。
  /// [context] 可以是本 widget 自身的 element，也可以是其后代。
  @visibleForTesting
  static double progressOf(BuildContext context) {
    _PageCurlViewState? state;
    if (context is StatefulElement && context.state is _PageCurlViewState) {
      state = context.state as _PageCurlViewState;
    }
    return (state ?? context.findAncestorStateOfType<_PageCurlViewState>())
            ?._drag ??
        0;
  }

  @override
  State<PageCurlView> createState() => _PageCurlViewState();
}

enum _TurnMode { idle, dragging, animating }

class _PageCurlViewState extends State<PageCurlView>
    with SingleTickerProviderStateMixin {
  // ---- 翻页状态机（对齐 realtime/index.html）----
  _TurnMode _mode = _TurnMode.idle;
  late int _page;
  int _target = 0;
  int _dir = 1; // 1 = 下一页（右缘掀起），-1 = 上一页
  double _drag = 0; // 翻页进度 [0, 1]
  double _curve = 0; // 曲率跟手 [0, 1]（拖拽速度决定软硬）
  double _breath = 0; // idle 呼吸缩放增量
  double _vx = 0; // 平滑后的水平速度（px/s）
  Offset _startPos = Offset.zero;
  Duration _lastMoveTime = Duration.zero;
  double _dragFrom = 0;
  double _dragTo = 0;
  Duration _animStart = Duration.zero;
  bool _commit = false;
  bool _backMounted = false;

  // ---- 快照（按需截屏）----
  final GlobalKey _frontKey = GlobalKey();
  final GlobalKey _backKey = GlobalKey();
  ui.Image? _frontImage; // 当前页快照（idle 常驻，呼吸与卷曲共用）
  ui.Image? _backImage; // 目标页快照（仅翻页期间）
  int _generation = 0; // 截屏世代号：翻页切换/内容变更后丢弃在途截屏

  // ---- 页面子树缓存：手势帧不重调 builder ----
  Widget? _cachedFront;
  Widget? _cachedBack;
  int _cachedFrontPage = -1;
  int _cachedBackPage = -1;
  bool _buildersChanged = false;

  late final Ticker _ticker;
  final _TurnNotifier _notifier = _TurnNotifier();
  Duration _clock = Duration.zero; // ticker 相对时钟（Ticker 无 elapsed getter）
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage;
    _ticker = createTicker(_onTick);
    if (widget.idleBreath) _ticker.start();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => unawaited(_captureIdleFront()));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = widget.respectReducedMotion &&
        (MediaQuery.maybeOf(context)?.disableAnimations ?? false);
  }

  @override
  void didUpdateWidget(PageCurlView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内容源变化：静帧快照与子树缓存作废（翻页进行中不打断本次翻页）。
    if (oldWidget.frontBuilder != widget.frontBuilder ||
        oldWidget.backBuilder != widget.backBuilder ||
        oldWidget.pageCount != widget.pageCount ||
        oldWidget.initialPage != widget.initialPage) {
      _buildersChanged = true;
      if (_page >= widget.pageCount) _page = widget.pageCount - 1;
      if (_mode == _TurnMode.idle) {
        _generation++;
        final img = _frontImage;
        _frontImage = null;
        img?.dispose();
        _notifier.repaint();
        WidgetsBinding.instance
            .addPostFrameCallback((_) => unawaited(_captureIdleFront()));
      }
    }
    // 呼吸开关即时生效。
    if (oldWidget.idleBreath != widget.idleBreath) {
      if (widget.idleBreath && !_reducedMotion) {
        if (!_ticker.isActive) _ticker.start();
      } else if (_mode == _TurnMode.idle) {
        _breath = 0;
        _ticker.stop();
        _notifier.repaint();
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _ticker.dispose();
    _notifier.dispose();
    _frontImage?.dispose();
    _backImage?.dispose();
    super.dispose();
  }

  // ---- 截屏 ----

  /// idle 首抓：当前页快照供呼吸微动与下一次翻页的卷曲源。
  Future<void> _captureIdleFront() async {
    if (!mounted || _mode != _TurnMode.idle || _reducedMotion) return;
    final img = await _capture(_frontKey);
    if (!mounted || img == null || _mode != _TurnMode.idle) {
      img?.dispose();
      return;
    }
    final old = _frontImage;
    _frontImage = img;
    old?.dispose();
    _notifier.repaint();
  }

  /// 翻页起步抓屏：front（当前页）+ back（目标页）。back host 挂载后的
  /// 下一帧执行（布局 + 绘制各一帧后才截得到内容）。
  Future<void> _captureForTurn() async {
    final gen = _generation;
    await _nextFrame();
    if (!mounted || gen != _generation) return;
    final front = await _capture(_frontKey);
    final back = await _capture(_backKey);
    if (!mounted || gen != _generation) {
      front?.dispose();
      back?.dispose();
      return;
    }
    final oldFront = _frontImage;
    final oldBack = _backImage;
    _frontImage = front;
    _backImage = back;
    oldFront?.dispose();
    oldBack?.dispose();
    _notifier.repaint();
  }

  Future<void> _nextFrame() {
    final c = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => c.complete());
    return c.future;
  }

  Future<ui.Image?> _capture(GlobalKey key) async {
    try {
      final boundary =
          key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null || !boundary.attached || boundary.size.isEmpty) {
        return null;
      }
      final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
      var ratio = dpr.clamp(1.0, 3.0);
      // 长边 2048 封顶，防大屏高分页快照内存失控。
      final longest = math.max(boundary.size.width, boundary.size.height);
      if (longest * ratio > 2048) ratio = 2048 / longest;
      return await boundary.toImage(pixelRatio: ratio);
    } catch (_) {
      return null; // 截屏失败 → 本次翻页退化为瞬时切页
    }
  }

  // ---- 状态机 ----

  void _onTick(Duration elapsed) {
    _clock = elapsed;
    switch (_mode) {
      case _TurnMode.animating:
        final raw = (elapsed - _animStart).inMicroseconds /
            widget.turnDuration.inMicroseconds;
        final t = raw.clamp(0.0, 1.0);
        final eased = _commit ? _overshoot(t) : _easeInOutCubic(t);
        _drag = _dragFrom + (_dragTo - _dragFrom) * eased;
        if (raw >= 1.0) {
          _finishTurn();
        } else {
          if (_reducedMotion) {
            setState(() {});
          } else {
            _notifier.repaint();
          }
        }
      case _TurnMode.idle:
        if (!widget.idleBreath || _reducedMotion) break;
        final sec = elapsed.inMicroseconds / 1e6;
        _breath = 0.004 * math.sin(2 * math.pi * sec / 6);
        _notifier.repaint(); // 快照绘制：零 widget 重建
      case _TurnMode.dragging:
        break; // 进度由手势回调驱动
    }
  }

  void _beginTurn(int dir) {
    final target = _page + dir;
    if (target < 0 || target >= widget.pageCount) return;
    _dir = dir;
    _target = target;
    _drag = 0;
    _curve = 0;
    setState(() => _backMounted = true);
    widget.onPageTurnStart?.call(_page, _target);
    if (_reducedMotion) return; // 平移淡入淡出路径不截屏
    unawaited(_captureForTurn());
    if (!_ticker.isActive) _ticker.start();
  }

  void _startAnim(
      {required bool commit, required double from, required double to}) {
    _commit = commit;
    _dragFrom = from;
    _dragTo = to;
    if (!_ticker.isActive) {
      // ticker 重启后 elapsed 归零，动画起点必须对齐，否则补间卡死在 from。
      _animStart = Duration.zero;
      _mode = _TurnMode.animating;
      _ticker.start();
    } else {
      _animStart = _clock;
      _mode = _TurnMode.animating;
    }
  }

  void _finishTurn() {
    final committed = _commit;
    final from = _page;
    final to = _target;
    _generation++; // 丢弃在途截屏（快翻时截屏可能落后于状态切换）
    var recaptureAfterCommit = false;
    setState(() {
      if (committed) {
        _page = _target;
        // 目标页快照晋升为当前页快照（零重复截屏）；截屏失败则退回
        // 「无快照」态，post-frame 重抓新页。
        final promoted = _backImage;
        _backImage = null;
        final oldFront = _frontImage;
        _frontImage = promoted;
        oldFront?.dispose();
        recaptureAfterCommit = promoted == null;
      } else {
        final back = _backImage;
        _backImage = null;
        back?.dispose();
      }
      _backMounted = false;
      _drag = 0;
      _curve = 0;
      _breath = 0;
      _mode = _TurnMode.idle;
    });
    if (recaptureAfterCommit) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => unawaited(_captureIdleFront()));
    }
    // 强制重绘终态：ticker 即将停止（无呼吸）时，补间末帧必须落到画布。
    _notifier.repaint();
    widget.onPageTurnEnd?.call(from, to, committed);
    if (!widget.idleBreath || _reducedMotion) _ticker.stop();
  }

  // ---- 手势 ----

  void _onDragStart(DragStartDetails d) {
    if (_mode != _TurnMode.idle || widget.pageCount < 2) return;
    final width = _viewWidth();
    if (width <= 0) return;
    final dir = d.localPosition.dx > width / 2 ? 1 : -1;
    final target = _page + dir;
    if (target < 0 || target >= widget.pageCount) return;
    _startPos = d.localPosition;
    _lastMoveTime = _clock;
    _vx = 0;
    _mode = _TurnMode.dragging;
    _beginTurn(dir);
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_mode != _TurnMode.dragging) return;
    final width = _viewWidth();
    if (width <= 0) return;
    final now = _clock;
    final dt = (now - _lastMoveTime).inMicroseconds / 1e6;
    _lastMoveTime = now;
    if (dt > 0) {
      final instV = d.delta.dx / dt;
      _vx = 0.7 * _vx + 0.3 * instV; // px/s 平滑（对齐参考实现）
    }
    final dx = d.localPosition.dx - _startPos.dx;
    // 下一页（dir=+1）向左拖（dx<0）进度应递增，故取反号。
    final raw = -_dir * dx / width;
    _drag = raw.clamp(0.0, 1.0);
    _curve = (_vx.abs() / 2600).clamp(0.0, 1.0);
    if (_frontImage != null && _backImage != null) {
      _notifier.repaint(); // 快照就绪：局部重绘，零重建
    } else {
      setState(() {}); // 截屏未就绪：底层 widget 显示（进度此时不可见）
    }
  }

  void _onDragEnd(DragEndDetails d) {
    if (_mode != _TurnMode.dragging) return;
    final width = _viewWidth();
    final pv = d.primaryVelocity ?? 0.0;
    final vProgress = width > 0 ? pv * _dir / width : 0.0;
    if (_drag > widget.commitThreshold || vProgress > widget.commitVelocity) {
      _startAnim(commit: true, from: _drag, to: 1);
    } else {
      _startAnim(commit: false, from: _drag, to: 0);
    }
  }

  void _onTapUp(TapUpDetails d) {
    if (!widget.enableTapTurn || _mode != _TurnMode.idle) return;
    final width = _viewWidth();
    if (width <= 0 || widget.pageCount < 2) return;
    final dir = d.localPosition.dx > width / 2 ? 1 : -1;
    if (_page + dir < 0 || _page + dir >= widget.pageCount) return;
    _beginTurn(dir);
    _startAnim(commit: true, from: 0, to: 1);
  }

  double _viewWidth() {
    final box = context.findRenderObject() as RenderBox?;
    return box?.size.width ?? 0;
  }

  // ---- 子树缓存 ----

  Widget _frontChild() {
    if (_buildersChanged || _cachedFront == null || _cachedFrontPage != _page) {
      _cachedFront = widget.frontBuilder(context, _page);
      _cachedFrontPage = _page;
      if (_mode == _TurnMode.idle) _buildersChanged = false;
    }
    return _cachedFront!;
  }

  Widget? _backChild() {
    if (!_backMounted) return null;
    if (_buildersChanged || _cachedBack == null || _cachedBackPage != _target) {
      _cachedBack = widget.backBuilder(context, _target);
      _cachedBackPage = _target;
    }
    return _cachedBack;
  }

  @override
  Widget build(BuildContext context) {
    if (_reducedMotion) {
      // 减弱动态：简单平移淡入淡出（无卷曲、无截屏、无呼吸）。
      final back = _backChild();
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        onTapUp: _onTapUp,
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (back != null) back,
              FractionalTranslation(
                translation: Offset(_dir * _drag * 0.33, 0),
                child: Opacity(
                  opacity: (1 - _drag * 1.4).clamp(0.0, 1.0),
                  child: _frontChild(),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onTapUp: _onTapUp,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // back host：翻页期间挂载（截屏源 + 快照未就绪时的兜底显示）。
            if (_backMounted)
              RepaintBoundary(key: _backKey, child: _backChild()),
            // front host：常驻（截屏源 + 快照未就绪时的原生显示）。
            RepaintBoundary(key: _frontKey, child: _frontChild()),
            CustomPaint(
              painter: _CurlPainter(this),
              isComplex: true,
              willChange: _mode != _TurnMode.idle,
            ),
          ],
        ),
      ),
    );
  }
}

/// Painter 的 repaint 通知（进度/呼吸变化 → 局部重绘）。
class _TurnNotifier extends ChangeNotifier {
  /// State 不继承 ChangeNotifier，经此公开方法触发局部重绘
  /// （notifyListeners 是 protected 成员，外部类不可直调）。
  void repaint() => notifyListeners();
}

/// 卷页绘制器：全部状态实时读自 [_PageCurlViewState]（painter 每帧重画时
/// 拿到的就是当前值）；repaint 由 notifier 驱动，widget 重建不重绘。
class _CurlPainter extends CustomPainter {
  _CurlPainter(this._s) : super(repaint: _s._notifier);

  final _PageCurlViewState _s;

  static const Color _ink = Color(0xFF1E1C18); // rgba(30,28,24)
  static const Color _foldInk = Color(0xFF191612); // rgba(25,22,18)
  static const Color _paperBack = Color(0xFFEFEEE5); // rgba(239,236,229)

  @override
  void paint(Canvas canvas, Size size) {
    final front = _s._frontImage;
    if (front == null) return; // 快照未就绪：底层原生 widget 直接可见
    final w = size.width;
    final h = size.height;
    final progress = _s._drag;
    final dir = _s._dir;
    final curve = _s._curve;

    canvas.save();
    // idle 呼吸：整体极缓缩放（画布变换，零额外栅格）。
    if (_s._breath != 0) {
      final s = 1 + _s._breath;
      canvas.translate(w / 2, h / 2);
      canvas.scale(s, s);
      canvas.translate(-w / 2, -h / 2);
    }

    final back = _s._backImage;
    if (progress <= 0.001 || back == null) {
      _drawPage(canvas, front, w, h);
      _drawPageBorder(canvas, w, h);
      canvas.restore();
      return;
    }

    final p = progress.clamp(0.0, 1.0);

    // 底：目标页（下一页在下面）。
    _drawPage(canvas, back, w, h);

    // 目标页上的投影：模拟掀起的页面遮光，随进度加深。
    final sh = 0.10 + 0.22 * math.sin(math.pi * p);
    final hingeLeft = dir > 0;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(hingeLeft ? 0 : w, 0),
          Offset(hingeLeft ? w : 0, 0),
          [
            _ink.withValues(alpha: sh * 0.9),
            _ink.withValues(alpha: sh * 0.35),
            _ink.withValues(alpha: 0),
          ],
          const <double>[0, 0.5, 1.0],
        ),
    );

    // 上面：当前页卷曲（条带圆柱投影近似，对齐参考实现的 strip 循环）。
    final follow = 1 - p;
    if (follow > 0.001) {
      final axisX = hingeLeft ? w * (1 - follow) : w * follow;
      final span = w * follow;
      final strips = _s.widget.curlStrips;
      final imgPaint = Paint()..filterQuality = FilterQuality.medium;
      for (var s = 0; s < strips; s++) {
        final u0 = s / strips;
        final u1 = (s + 1) / strips;
        final midU = (u0 + u1) / 2;
        // 条带相对折轴的距离（0 = 折轴处，1 = 翻起侧外缘）。
        final dist =
            ((hingeLeft ? w * midU - axisX : axisX - w * midU) / (span + 0.0001));
        if (dist < 0) continue;
        final d = dist.clamp(0.0, 1.0);
        // 压缩映射：靠近折轴压缩多（cos 曲线），curve 调节软硬。
        final compress =
            math.cos(d * math.pi / 2 * (0.65 + 0.35 * curve)).abs();
        final bw = (u1 - u0) * w * math.max(0.12, compress) + 0.6;
        final bx = hingeLeft ? axisX + u0 * span : axisX - u1 * span;
        final dst = Rect.fromLTRB(bx, 0, bx + bw, h);
        if (dst.right <= 0 || dst.left >= w) continue;
        // 源条带（整页坐标，反向翻页时源序也镜像）。
        final su0 = hingeLeft ? u0 : 1 - u1;
        final su1 = hingeLeft ? u1 : 1 - u0;
        imgPaint.color = const Color(0xFFFFFFFF);
        canvas.drawImageRect(
            front,
            ui.Rect.fromLTRB(
                su0 * front.width, 0, su1 * front.width, front.height.toDouble()),
            dst,
            imgPaint);
        // 圆柱高光：折轴附近提亮。
        final glow = math.pow(1 - d, 3).toDouble() * 0.28;
        if (glow > 0.004) {
          canvas.drawRect(
              dst,
              Paint()
                ..color = const Color(0xFFFFFCF0).withValues(alpha: glow));
        }
        // 背面透色（接近翻完时见纸背）。
        if (d > 0.86 && p > 0.5) {
          final a =
              ((d - 0.86) / 0.14 * 0.85 * ((p - 0.5) * 2).clamp(0.0, 1.0))
                  .clamp(0.0, 1.0);
          canvas.drawRect(dst,
              Paint()..color = _paperBack.withValues(alpha: a));
        }
      }
      // 卷轴落影：投在下一页上。
      canvas.drawRect(
        Rect.fromLTRB(axisX - 24 * dir, 0, axisX - 24 * dir + 56, h),
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(axisX - 18 * dir, 0),
            Offset(axisX + 30 * dir, 0),
            [
              _foldInk.withValues(alpha: 0),
              _foldInk.withValues(
                  alpha: 0.34 * (0.4 + 0.6 * math.sin(math.pi * p))),
              _foldInk.withValues(alpha: 0),
            ],
            const <double>[0, 0.5, 1.0],
          ),
      );
      // 页缘细阴影（外缘）。
      canvas.drawRect(
        Rect.fromLTRB(hingeLeft ? w - 10 : 0, 0, hingeLeft ? w : 10, h),
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(hingeLeft ? w - 10 : 10, 0),
            Offset(hingeLeft ? w : 0, 0),
            [
              _ink.withValues(alpha: 0),
              _ink.withValues(alpha: 0.18),
            ],
          ),
      );
    }
    _drawPageBorder(canvas, w, h);
    canvas.restore();
  }

  void _drawPage(Canvas canvas, ui.Image img, double w, double h) {
    canvas.drawImageRect(
      img,
      ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(0, 0, w, h),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  void _drawPageBorder(Canvas canvas, double w, double h) {
    canvas.drawRect(
        Rect.fromLTWH(0.5, 0.5, w - 1, h - 1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFF26241F).withValues(alpha: 0.18));
  }

  @override
  bool shouldRepaint(_CurlPainter oldDelegate) => false;
}

// ---- 缓动（对齐 realtime/index.html）----

/// ease-in-out 三次方。
double _easeInOutCubic(double t) =>
    t < 0.5 ? 4 * t * t * t : 1 - _pow3(-2 * t + 2) / 2;

double _pow3(double v) => v * v * v;

/// 回弹过冲：t<0.82 ease-out 到 1.045，随后收回 1.0（鸿蒙式 rubber band）。
double _overshoot(double t) {
  if (t < 0.82) return _easeOutCubic(t / 0.82) * 1.045;
  final u = (t - 0.82) / 0.18;
  return 1.045 - 0.045 * _easeInOutCubic(u);
}

double _easeOutCubic(double t) => 1 - _pow3(1 - t);
