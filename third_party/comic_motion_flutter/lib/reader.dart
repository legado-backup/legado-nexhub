/// 互动阅读入口：分格清单、布局、聚焦控制器与可叠加的渲染层。
///
/// 与主入口 `comic_motion_flutter.dart` 分开导出，阅读器可以只 import
/// `package:comic_motion_flutter/reader.dart`，不把 GIF/视差/卷页 API
/// 带进命名空间。核心引擎仍由 `comic_motion` 提供，本入口不新增依赖。
///
/// 三层体验：
/// - T0：无清单，整页作为隐式分格，用现成整页 GIF 做聚焦/撕开揭示；
/// - T1：`comic_panels` 清单提供归一化分格，聚焦格裁剪整页 GIF；
/// - T2：清单 `clip.asset` + 宿主加载的每格素材，格内独立播放。
library;

export 'src/reader/interactive_page_layer.dart';
export 'src/reader/panel_focus.dart';
export 'src/reader/panel_layout.dart';
export 'src/reader/panel_manifest.dart';
