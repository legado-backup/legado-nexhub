# comic_motion_flutter

[English](README.md) | [简体中文](README_zh-CN.md)

核心包 [**comic_motion**](../comic_motion) 的 Flutter 伴生包——提供直接
消费引擎渲染产物的即用 widgets，嵌入方无需自己写解码与动画代码。

核心包保持**纯 Dart**（零 Flutter 依赖）；本包为单向依赖的伴生包：

```
comic_motion（纯 Dart 引擎）  ←  comic_motion_flutter（widgets）
                              ←  comic_motion_server（CLI / HTTP）
                              ←  comic_motion_shaders（GPU 实时渲染）
```

## Widgets

### MotionGifView —— 全量渲染产物的播放视图

| 能力 | 说明 |
|---|---|
| 占位无缝过渡 | `firstFramePng` 立即上屏，GIF 首帧解码完成后 crossfade 淡出（默认 150ms，`Duration.zero` = 直切） |
| 播放控制 | `playing` 外部驱动暂停/恢复；`loop: false` 播完停在末帧 |
| 减弱动态 | 跟随 `MediaQuery.disableAnimations`——静帧占位、不解码动画（`respectReducedMotion`） |
| 入场帧 | 可选的 V2 入场 PNG 序列前置播放（模糊 → 清晰浮现），随后无缝切入 GIF 循环 |
| 功耗感知（W4） | 生命周期离开 resumed 自动静帧；`pauseWhenNotVisible` 开启后滚出视口即静帧、滚回恢复；`enableMotion` 钩子把策略决策权交给 App（如低电量）——**本包不引 battery 依赖** |

```dart
MotionGifView(
  gifBytes: gif,            // MemoryPipelineResult.gifBytes / anim.gif
  firstFramePng: cover,     // MemoryPipelineResult.firstFramePng
  entranceFrames: entrance, // 可选：exportEntranceFrames 产物
)
```

### ParallaxGyroView —— V1 交互帧集的跟手视差视图

三种输入驱动（注入流非空时优先）：

1. **陀螺仪**（默认）——加速度计 → 归一化倾斜相位（`maxTiltDeg`，默认
   15° 满偏），~60fps 节流 + 0.01 死区；
2. **触摸回退**（`touchFallback`）——平移手势按「半视口拖动 = 满相位」
   换算；桌面端 / 无传感器设备开箱即用；
3. **注入流**（`tiltStream`）——`Stream<Offset>`，值域 [-1,1]；不订阅
   传感器。这是测试 mock 与自定义驱动（摇杆等）的挂点。

插值（`smooth`）：`true`（默认）相邻两帧 alpha 混合，慢速倾斜顺滑；
`false` 最近帧直切，零开销基线。

功耗感知（W4）：与 MotionGifView 同款三路信号——生命周期静帧（默认）、
`pauseWhenNotVisible` 滚动视口检测（opt-in）、`enableMotion` App 钩子；
抑制时**完全断开**传感器/注入流订阅（零持续开销），恢复自动重连。

```dart
final sets = await loadInteractionSets(interactiveDir); // 磁盘
// 或：loadInteractionSetsFromIndexJson(indexBytes, loadFrame: ...) // 资产

ParallaxGyroView(frames: sets.first) // both 导出：按展示位各取一组
```

### PageCurlView —— 仿真卷页翻页视图（W1）

`realtime/index.html` Canvas 参考实现的 Flutter 移植，对齐鸿蒙翻页手感：

- **卷页曲率**——当前页按纵向条带绘制，折轴附近按圆柱投影压缩；拖拽速度
  决定页面软硬（`curlStrips`，默认 28 条）；
- **拖拽跟手**——进度 = 水平位移 / 视宽，钳制 [0,1]；
- **松手回弹过冲**——越过 `commitThreshold`（0.32）或甩动速度阈值，
  以峰值 1.045 的 rubber-band 缓动落页，否则原路弹回；
- **双层光影**——条带高光、纸背透色、折轴落影（投在下一页）、页缘阴影；
- **idle 呼吸微动**——整页 ±0.4%、6s 周期浮沉（`idleBreath`）。

页面内容**翻页开始的瞬间按需截屏**（RepaintBoundary → front/back 两页
`ui.Image`）；手势帧经 `CustomPainter` + repaint listenable 局部重绘——
零 widget 重建、builder 不重调。`onPageTurnStart` / `onPageTurnEnd` 供
App 自接音效/触觉（本包不引 audio/vibration 依赖）。系统「减弱动态」
回退为平移淡入淡出。

```dart
PageCurlView(
  pageCount: chapters.length,
  frontBuilder: (context, i) => ChapterPage(i),
  backBuilder: (context, i) => ChapterPage(i),
  onPageTurnStart: (from, to) => Haptics.lightImpact(),
)
```

### InteractivePageLayer —— 聚焦撕开式互动阅读

独立入口（`package:comic_motion_flutter/reader.dart`）提供的可选覆盖层。
点按页面/分格中心：聚焦区域保持清晰并播放动效，其余区域压暗，动效以
420ms 斜锯齿撕开揭示；再点收回。三层体验：

- **T0 整页**——无需清单，复用现成整页 GIF；
- **T1 分格**——`comic_panels` JSON 提供归一化矩形，聚焦格裁剪整页 GIF，
  其余压暗；
- **T2 格素材**——清单 `clip.asset` + 宿主加载的每格字节。

```dart
InteractivePageLayer(
  gifBytes: gif,
  firstFramePng: cover,
  child: page,            // 宿主已画静态页时省略，作纯覆盖层
  // manifest: PanelManifest.fromBytes(jsonBytes),
  // imageSize: pageSize, // T1 必填
  // controller: focusController,
  // gazeStream: gaze,    // 归一化 [0,1] 页面坐标
  // interactive: true,   // 外层无手势层时
)
```

外层已有阅读器手势层时不要开 `interactive`，改用 `GlobalKey` 调
`state.handleTap(globalPosition)`。系统减弱动态下保留静帧与聚焦轮廓，
无撕开/呼吸/缩放；功耗抑制时暂停 GIF 与呼吸。`PanelManifest`、
`PanelLayout`、`PanelFocusController` 均为纯 Dart 构件，可脱离 widget
树单测。

## 纯 Dart 辅助工具（不依赖 Flutter 即可单测）

- `loadInteractionSets(dir)`——从磁盘加载 `<...>_interactive/` 目录；
- `loadInteractionSetsFromIndexJson(bytes, loadFrame:)`——任意字节存储
  （资产、网络、WASM）经取字节回调加载；
- `tiltToPhase(ax, ay, az, maxTiltRad)`——加速度计 → `(phaseX, phaseY)`，
  参考倾斜模型（roll/pitch 的 atan2 归一化）。

## 内存提示

- 帧集 PNG 经 `Image` 的解码缓存常驻（受全局 `ImageCache` 上限约束）；
  帧集分辨率建议 ≤ 显示尺寸的 1.5 倍。
- `MotionGifView` 经 `ui.instantiateImageCodec` 解码；重渲染活属于核心包
  的后台入口（`processFileInBackground` 等）——见核心包 README「线程模型」。

## 安装

```yaml
dependencies:
  comic_motion_flutter: ^0.2.0
```

monorepo 内各包以 `pubspec_overrides.yaml` 的 path 依赖互联，见
`comic_motion_flutter/pubspec_overrides.yaml`。

## 环境要求

| 项目 | 要求 |
|---|---|
| Flutter | ≥ 3.22（Dart ≥ 3.4.0） |
| 核心包 | `comic_motion: ^1.3.0` |
| 传感器（可选） | `sensors_plus ^6.1.1`——仅 `tiltStream` 为空时使用 |

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。
