/// MotionGifView：消费核心包 `processBytes` 产物的 GIF 播放视图。
///
/// 能力：
/// - **占位无缝过渡**：先用 `firstFramePng` 占位，GIF 首帧解码完成后按
///   [crossfadeDuration] 淡出占位（默认 150ms；`Duration.zero` = 直切）。
///   契约上 GIF 首帧与 firstFramePng 同源，但 GIF 经调色板量化存在细微
///   色差——短 crossfade 可以掩盖这次「pop」。
/// - **播放 / 暂停 / 循环控制**：`playing` 外部驱动；`loop: false` 播完
///   停在末帧。
/// - **减弱动态**：系统「减弱动态」开启（`MediaQuery.disableAnimations`）
///   时自动静帧显示 firstFramePng，不解码动画（[respectReducedMotion]）。
/// - **入场帧前置播放**：传入 V2 `exportEntranceFrames` 的 PNG 帧序列，
///   先按 `entranceDelayMs` 逐帧播放（模糊→清晰浮现），结束后无缝切入
///   GIF 循环（入场末帧 = 清晰原图 ≈ GIF 视觉基调）。
/// - **功耗感知（W4）**：`AppLifecycleState` 离开 resumed 自动静帧；
///   `pauseWhenNotVisible` 开启后滚出视口即静帧、滚回恢复（滚动通知 +
///   RenderBox 视口求交，覆盖滚动可见性；静态遮挡不检测）；`enableMotion`
///   钩子把策略决策权交给 App（如低电量静帧），本包不引 battery 依赖。
///   静帧 = 停止泵帧循环（generation 失效），恢复按需重启，零持续开销。
///
/// 线程模型：本组件只消费已编码字节。渲染（解码前的动效生成）属重活，
/// 请用核心包的后台 isolate 入口（processBytesInBackground 等）在后台
/// 完成后再喂给本组件，见核心包 README「线程模型」。
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'power_aware.dart';

class MotionGifView extends StatefulWidget {
  const MotionGifView({
    super.key,
    required this.gifBytes,
    this.firstFramePng,
    this.entranceFrames,
    this.entranceDelayMs = 80,
    this.playing = true,
    this.loop = true,
    this.crossfadeDuration = const Duration(milliseconds: 150),
    this.respectReducedMotion = true,
    this.pauseWhenNotVisible = false,
    this.enableMotion,
    this.fit = BoxFit.contain,
    this.width,
    this.height,
    this.semanticLabel,
  });

  /// 核心包渲染产物（`MemoryPipelineResult.gifBytes` / anim.gif 字节）。
  final Uint8List gifBytes;

  /// 首帧封面 PNG（`firstFramePng` / frame_0000.png）。占位与减弱动态
  /// 静帧都用它；为 null 时占位层为空（背景色兜底）。
  final Uint8List? firstFramePng;

  /// 入场帧序列（V2 `exportEntranceFrames` 的 PNG 帧，首→末 = 模糊→清晰）。
  /// 非 null 时前置播放，播完停在末帧并切入 GIF 循环。
  final List<Uint8List>? entranceFrames;

  /// 入场帧播放间隔（毫秒）。
  final int entranceDelayMs;

  /// 是否播放（外部驱动；false = 暂停在当前帧）。
  final bool playing;

  /// true = 无限循环；false = 播一次停在末帧。
  final bool loop;

  /// 占位 → GIF 首帧的过渡时长；Duration.zero = 直切。
  final Duration crossfadeDuration;

  /// 系统减弱动态开启时静帧（true，默认）。
  final bool respectReducedMotion;

  /// 视口外自动暂停（W4，默认 false 向后兼容）：滚出视口即静帧、滚回
  /// 恢复。基于滚动通知 + RenderBox 视口求交，覆盖滚动可见性；静态遮挡
  /// （Stack 深处被盖住等）不检测。
  final bool pauseWhenNotVisible;

  /// App 策略钩子（W4）：返回 false 即静帧（如低电量）。决策权在 App，
  /// 本包不引 battery 依赖。返回值变化后 App rebuild 触发重估。
  final bool Function()? enableMotion;

  final BoxFit fit;
  final double? width;
  final double? height;
  final String? semanticLabel;

  @override
  State<MotionGifView> createState() => _MotionGifViewState();
}

class _MotionGifViewState extends State<MotionGifView>
    with MotionPowerAware<MotionGifView> {
  ui.Codec? _codec;
  ui.Image? _currentFrame;
  bool _gifLoaded = false;
  bool _failed = false;
  bool _entranceDone = false;
  int _entranceIndex = 0;
  int _generation = 0;
  bool _reducedMotion = false;

  @override
  bool Function()? get enableMotion => widget.enableMotion;

  @override
  bool get pauseWhenNotVisible => widget.pauseWhenNotVisible;

  @override
  void initState() {
    super.initState();
    motionPowerInit();
    // 延后到首帧 build 之后：_reducedMotion 依赖 didChangeDependencies 里
    // 的 MediaQuery 读取，直接在 initState 跑会读到初始 false。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bootstrap();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = widget.respectReducedMotion &&
        (MediaQuery.maybeOf(context)?.disableAnimations ?? false);
  }

  @override
  void didUpdateWidget(MotionGifView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.gifBytes != oldWidget.gifBytes) {
      _reset();
      _bootstrap();
      return;
    }
    if (widget.playing != oldWidget.playing) {
      if (widget.playing) {
        if (motionActive) _resume();
      } else {
        _generation++; // 暂停：终止在途泵帧循环
      }
    }
    // 钩子/视口开关变化后重估功耗聚合（可能触发恢复/静帧）。
    reassessMotion();
  }

  // ---- W4 功耗感知：静帧 = 终止泵帧循环；恢复 = 按需重启 ----

  @override
  void onMotionSuppressed() {
    _generation++; // 终止在途泵帧循环（与 playing=false 同路径）
  }

  @override
  void onMotionRestored() {
    if (widget.playing) _resume();
  }

  void _reset() {
    _generation++;
    _codec?.dispose();
    _codec = null;
    _currentFrame?.dispose();
    _currentFrame = null;
    _gifLoaded = false;
    _failed = false;
    _entranceDone = widget.entranceFrames == null;
    _entranceIndex = 0;
  }

  Future<void> _bootstrap() async {
    _entranceDone = widget.entranceFrames == null;
    // 入场帧前置播放（独立 Future，不阻塞 GIF 解码）。
    if (widget.entranceFrames case final frames? when frames.isNotEmpty) {
      unawaited(_playEntrance(frames));
    }
    // 减弱动态：不解码动画，保持占位静帧。
    if (_reducedMotion) return;
    try {
      final codec = await ui.instantiateImageCodec(widget.gifBytes);
      if (!mounted) {
        codec.dispose();
        return;
      }
      _codec = codec;
      // 先取首帧显示（与占位同源，crossfade 由此刻开始）。
      final first = await codec.getNextFrame();
      if (!mounted || _codec != codec) {
        first.image.dispose();
        return;
      }
      _showFrame(first.image);
      // W4：功耗聚合不允许时（后台/屏外/钩子 false）不启动泵帧循环；
      // 恢复路径由 onMotionRestored 接管。
      if (widget.playing && motionActive) {
        unawaited(_pump(codec, startAt: 1));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _failed = true);
      }
    }
  }

  /// 入场帧序列：逐帧 delayMs，播完 holdOnLast（末帧保持到 GIF 接管）。
  Future<void> _playEntrance(List<Uint8List> frames) async {
    final delay = Duration(milliseconds: widget.entranceDelayMs.clamp(1, 5000));
    for (var i = 0; i < frames.length; i++) {
      if (!mounted) return;
      setState(() => _entranceIndex = i);
      await Future<void>.delayed(delay);
    }
    if (!mounted) return;
    // 入场序列 holdOnLast：末帧 = 清晰原图，随后切入 GIF 循环。
    setState(() => _entranceDone = true);
  }

  void _showFrame(ui.Image image) {
    final old = _currentFrame;
    setState(() {
      _currentFrame = image;
      _gifLoaded = true;
    });
    old?.dispose();
  }

  /// 从 [startAt] 帧序号开始泵帧；世代号不匹配或暂停即退出。
  Future<void> _pump(ui.Codec codec, {int startAt = 0}) async {
    final gen = _generation;
    var index = startAt;
    while (mounted && widget.playing && gen == _generation && _codec == codec) {
      final frame = await codec.getNextFrame();
      if (!mounted || gen != _generation || _codec != codec) {
        frame.image.dispose();
        return;
      }
      _showFrame(frame.image);
      final last = index >= codec.frameCount - 1;
      if (!widget.loop && last) {
        return; // 播完停在末帧（holdOnLast）
      }
      index = last ? 0 : index + 1;
      await Future<void>.delayed(frame.duration);
      if (!mounted || gen != _generation || _codec == null) return;
    }
  }

  void _resume() {
    final codec = _codec;
    if (codec == null || !mounted) return;
    unawaited(_pump(codec));
  }

  @override
  void dispose() {
    motionPowerDispose();
    _generation++;
    _codec?.dispose();
    _currentFrame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = widget.firstFramePng;
    final showPlaceholder = !_gifLoaded || _reducedMotion;
    final entrance = widget.entranceFrames;
    final showEntrance = !_entranceDone &&
        entrance != null &&
        entrance.isNotEmpty &&
        _entranceIndex < entrance.length;

    Widget content = SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // GIF 帧（解码完成后出现；失败时保持占位）。
            if (_currentFrame != null)
              // RawImage 无 semanticLabel 参数——仅在有标签时包 Semantics。
              widget.semanticLabel == null
                  ? RawImage(image: _currentFrame, fit: widget.fit)
                  : Semantics(
                      image: true,
                      label: widget.semanticLabel,
                      child: RawImage(image: _currentFrame, fit: widget.fit),
                    )
            else if (placeholder != null && _failed)
              Image.memory(
                placeholder,
                fit: widget.fit,
                semanticLabel: widget.semanticLabel,
              ),
            // 占位层：crossfade 淡出（Duration.zero = 直切）。
            if (placeholder != null && showPlaceholder && !showEntrance)
              AnimatedOpacity(
                opacity: _gifLoaded ? 0.0 : 1.0,
                duration: widget.crossfadeDuration,
                child: Image.memory(
                  placeholder,
                  fit: widget.fit,
                  semanticLabel: widget.semanticLabel,
                  gaplessPlayback: true,
                ),
              ),
            // 入场帧层（最上层）：播放期间完全遮住 GIF / 占位。
            if (showEntrance)
              AnimatedSwitcher(
                duration: widget.crossfadeDuration,
                child: Image.memory(
                  entrance[_entranceIndex],
                  key: ValueKey<int>(_entranceIndex),
                  fit: widget.fit,
                  semanticLabel: widget.semanticLabel,
                  gaplessPlayback: true,
                ),
              ),
          ],
        ),
      ),
    );
    // W4 视口暂停：滚动通知驱动惰性视口自检（opt-in）。
    if (!widget.pauseWhenNotVisible) return content;
    return NotificationListener<ScrollNotification>(
      onNotification: onMotionScrollNotification,
      child: content,
    );
  }
}
