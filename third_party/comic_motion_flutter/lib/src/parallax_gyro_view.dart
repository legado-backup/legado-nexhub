/// ParallaxGyroView：消费核心包交互帧集（V1 `exportInteractionFrames`）
/// 的跟手视差视图。
///
/// 输入驱动（二选一，自动回退）：
/// - **陀螺仪**（默认）：sensors_plus 加速度计（含重力）→ 欧拉角归一化
///   （[tiltToPhase]，[maxTiltDeg] 控制满偏角度）→ 相位 → 帧索引；
/// - **触摸拖动**（[touchFallback]）：平移手势按视口尺寸换算相位；桌面端
///   / 无传感器设备天然可用。**测试与自定义驱动**：[tiltStream] 注入
///   `Stream<Offset>`（Offset ∈ [-1,1] 直接作为相位），流非空时不订阅
///   传感器（可注入 mock，见 test/parallax_gyro_view_test.dart）。
///
/// 插值策略（[smooth]，默认 true = 相邻两帧 alpha 混合）：
/// - **混合**：慢速倾斜观感顺滑，解码内存 ≈ 相邻 2 帧（ImageCache 管理）；
/// - **直切**（false）：零开销基线，慢速倾斜有阶梯感。
///
/// 内存提示：帧集 PNG 常驻内存（`Image` widget 经 ImageCache 解码缓存，
/// 受全局 cache 上限约束）；帧集分辨率建议 ≤ 显示尺寸的 1.5 倍。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'parallax_math.dart';
import 'power_aware.dart';

class ParallaxGyroView extends StatefulWidget {
  const ParallaxGyroView({
    super.key,
    required this.frames,
    this.tiltStream,
    this.maxTiltDeg = 15.0,
    this.smooth = true,
    this.touchFallback = true,
    this.returnToCenter = true,
    this.pauseWhenNotVisible = false,
    this.enableMotion,
    this.fit = BoxFit.contain,
    this.semanticLabel,
  });

  /// 交互帧集（单轴：horizontal 或 vertical；both 产物请按展示位拆开传）。
  /// 来自 `exportInteractionFrames` 内存结果（`result.sets[i]`）或
  /// `loadInteractionSets(dir)` 磁盘加载。
  final InteractionFrameSet frames;

  /// 注入的相位流（每值 ∈ [-1,1]）。非 null 时**不**订阅传感器——测试
  /// mock 与自定义驱动（如摇杆）入口。
  final Stream<Offset>? tiltStream;

  /// 陀螺仪满偏角度（设备倾斜多少度对应 phase = ±1），默认 15°。
  final double maxTiltDeg;

  /// true = 相邻帧 alpha 混合（默认，顺滑）；false = 最近帧直切（零开销）。
  final bool smooth;

  /// 触摸拖动回退（默认开启）：无陀螺仪输入时仍可跟手。
  final bool touchFallback;

  /// 拖动结束后相位回中（true，默认；立即回中）。
  final bool returnToCenter;

  /// 视口外自动暂停（W4，默认 false 向后兼容）：滚出视口即断开传感器/
  /// 注入流订阅（静帧），滚回重连。基于滚动通知 + RenderBox 视口求交。
  final bool pauseWhenNotVisible;

  /// App 策略钩子（W4）：返回 false 即断开输入订阅（静帧，如低电量）。
  /// 决策权在 App，本包不引 battery 依赖。返回值变化后 rebuild 触发重估。
  final bool Function()? enableMotion;

  final BoxFit fit;
  final String? semanticLabel;

  @override
  State<ParallaxGyroView> createState() => _ParallaxGyroViewState();
}

class _ParallaxGyroViewState extends State<ParallaxGyroView>
    with MotionPowerAware<ParallaxGyroView> {
  static const double _phaseEpsilon = 0.01;

  double _phase = 0; // [-1, 1]
  StreamSubscription<Offset>? _injectedSub;
  StreamSubscription<AccelerometerEvent>? _sensorSub;
  DateTime _lastPhaseUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  bool Function()? get enableMotion => widget.enableMotion;

  @override
  bool get pauseWhenNotVisible => widget.pauseWhenNotVisible;

  @override
  void initState() {
    super.initState();
    motionPowerInit();
    _syncInput();
  }

  @override
  void didUpdateWidget(ParallaxGyroView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.frames, oldWidget.frames)) {
      _phase = widget.frames.phases.first == 0 ? 0 : _clamp(_phase);
      setState(() {});
    }
    if (widget.tiltStream != oldWidget.tiltStream ||
        widget.enableMotion != oldWidget.enableMotion ||
        widget.pauseWhenNotVisible != oldWidget.pauseWhenNotVisible) {
      // 订阅状态由功耗聚合统一驱动（抑制态不订阅）。
      _syncInput();
    }
    if (widget.maxTiltDeg != oldWidget.maxTiltDeg) {
      _lastPhaseUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    }
    // 钩子/开关变化后重估功耗聚合。
    reassessMotion();
  }

  // ---- W4 功耗感知：静帧 = 断开输入订阅；恢复 = 重连 ----

  @override
  void onMotionSuppressed() {
    _unsubscribe();
  }

  @override
  void onMotionRestored() {
    _syncInput();
  }

  /// 依据功耗聚合状态重建订阅：允许时连（注入流优先，否则传感器），
  /// 抑制时全断（零持续开销）。
  void _syncInput() {
    _unsubscribe();
    if (!motionActive) return;
    _subscribe();
  }

  void _subscribe() {
    final injected = widget.tiltStream;
    if (injected != null) {
      _injectedSub = injected.listen(_onInjectedPhase);
      return;
    }
    // 陀螺仪路径：加速度计含重力分量 → 倾斜相位（X 轴集用 roll，Y 轴集用
    // pitch）。~100Hz 事件流做节流：相位变化 < 0.01 或间隔 < 16ms 不重建。
    final isHorizontal = widget.frames.axis == InteractionAxis.horizontal;
    _sensorSub = accelerometerEventStream().listen((event) {
      final (phaseX, phaseY) = tiltToPhase(
        ax: event.x,
        ay: event.y,
        az: event.z,
        maxTiltRad: degToRad(widget.maxTiltDeg),
      );
      final next = isHorizontal ? phaseX : phaseY;
      _applyPhase(next);
    });
  }

  void _unsubscribe() {
    _injectedSub?.cancel();
    _injectedSub = null;
    _sensorSub?.cancel();
    _sensorSub = null;
  }

  void _onInjectedPhase(Offset phase) {
    final isHorizontal = widget.frames.axis == InteractionAxis.horizontal;
    _applyPhase(isHorizontal ? phase.dx : phase.dy);
  }

  /// 节流应用相位：变化过小或距上次重建 < 16ms（≈60fps）直接丢弃。
  void _applyPhase(double next) {
    final now = DateTime.now();
    if ((now.difference(_lastPhaseUpdate)).inMilliseconds < 16) return;
    if ((next - _phase).abs() < _phaseEpsilon) return;
    _lastPhaseUpdate = now;
    setState(() => _phase = _clamp(next));
  }

  double _clamp(double v) => v.clamp(-1.0, 1.0).toDouble();

  // ---- 触摸回退 ----

  void _onPanUpdate(DragUpdateDetails d) {
    if (!widget.touchFallback) return;
    final size = context.size;
    if (size == null || size.isEmpty) return;
    final isHorizontal = widget.frames.axis == InteractionAxis.horizontal;
    final delta = isHorizontal ? d.delta.dx : d.delta.dy;
    final span = isHorizontal ? size.width : size.height;
    if (span <= 0) return;
    // 半个视口宽/高的拖动 ≈ 满相位，手感自然。
    _applyPhase(_phase + delta / (span / 2));
  }

  void _onPanEnd(DragEndDetails d) {
    if (widget.returnToCenter) {
      setState(() => _phase = 0);
    }
  }

  @override
  void dispose() {
    motionPowerDispose();
    _unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frames = widget.frames;
    final pngBytes = frames.pngBytes;
    if (pngBytes.isEmpty) {
      return SizedBox.expand(child: widget.semanticLabel == null
          ? const SizedBox.shrink()
          : Text(widget.semanticLabel!));
    }

    Widget child;
    if (widget.smooth && pngBytes.length >= 2) {
      // 相邻帧 alpha 混合：pos 为相位在采样序列上的连续位置。
      final step = 2.0 / (frames.phases.length - 1);
      final pos =
          ((_phase - frames.phases.first) / step).clamp(0.0, (pngBytes.length - 1).toDouble());
      final i0 = pos.floor().clamp(0, pngBytes.length - 1);
      final i1 = math.min(i0 + 1, pngBytes.length - 1);
      final frac = pos - i0;
      if (i0 == i1 || frac <= 0) {
        child = _frameImage(pngBytes[i0]);
      } else {
        child = Stack(
          fit: StackFit.expand,
          children: [
            Opacity(opacity: 1 - frac, child: _frameImage(pngBytes[i0])),
            Opacity(opacity: frac, child: _frameImage(pngBytes[i1])),
          ],
        );
      }
    } else {
      // 最近帧直切（零开销基线）。
      final idx = frames.indexForPhase(_phase);
      child = _frameImage(pngBytes[idx]);
    }

    final gesture = widget.touchFallback
        ? GestureDetector(
            onPanUpdate: _onPanUpdate,
            onPanEnd: _onPanEnd,
            behavior: HitTestBehavior.opaque,
            child: child,
          )
        : child;
    Widget content = SizedBox.expand(child: ClipRect(child: gesture));
    // W4 视口暂停：滚动通知驱动惰性视口自检（opt-in）。
    if (!widget.pauseWhenNotVisible) return content;
    return NotificationListener<ScrollNotification>(
      onNotification: onMotionScrollNotification,
      child: content,
    );
  }

  Widget _frameImage(Uint8List bytes) => Image.memory(
        bytes,
        fit: widget.fit,
        semanticLabel: widget.semanticLabel,
        gaplessPlayback: true,
      );
}
