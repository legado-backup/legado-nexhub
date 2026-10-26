/// Flutter 伴生包：消费 `comic_motion` 渲染产物的即用 widgets 与加载工具。
///
/// 四类能力：
/// - **MotionGifView**：GIF 播放视图——占位 crossfade 无缝过渡、播放/暂停/
///   循环控制、减弱动态静帧、V2 入场帧前置播放；
/// - **PageCurlView**：仿真卷页翻页——卷页曲率、拖拽跟手、回弹过冲、
///   双层光影、idle 呼吸（W1）；
/// - **ParallaxGyroView**：跟手视差视图——V1 交互帧集（陀螺仪/触摸/注入流
///   三种驱动，相邻帧 alpha 混合或直切）；
/// - **纯 Dart 加载工具**：`loadInteractionSets`（磁盘/内存 index.json →
///   帧集）、`tiltToPhase`（加速度计 → 归一化相位），可脱离 Flutter 单测。
///
/// 功耗感知（W4）：`MotionGifView` / `ParallaxGyroView` 支持
/// `AppLifecycleState` 静帧、`pauseWhenNotVisible` 视口外自动暂停与
/// `enableMotion` App 策略钩子；自定义视图可复用 `MotionPowerAware` mixin。
///
/// 核心包保持纯 Dart（零 Flutter 依赖），本包单向依赖它——见核心包
/// README「生态」。
///
/// 互动阅读（分格聚焦 / 撕开揭示）在独立入口 `reader.dart`，不混入本
/// 命名空间。
library;

export 'src/motion_gif_view.dart';
export 'src/page_curl_view.dart';
export 'src/parallax_frames.dart';
export 'src/parallax_gyro_view.dart';
export 'src/parallax_math.dart';
export 'src/power_aware.dart';
