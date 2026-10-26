/// 交互帧集的加载模型（纯 Dart，无 Flutter 依赖，可独立单测）。
///
/// 消费核心包 `exportInteractionFrames` / `exportInteractionFramesFile`
/// 的产物（内存帧集或磁盘目录），把 index.json + 帧 PNG 组装成嵌入方可
/// 直接渲染的帧查找表。
library;

import 'dart:convert' as convert;
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';

/// 从磁盘目录加载交互帧集：`<...>_interactive/`（index.json +
/// frame_NNNN.png）。[dir] 为导出产物目录（`InteractionExportResult.outputDir`）。
///
/// 解析校验：kind 必须为 `interactive`；帧文件缺失即抛 [io.FileSystemException]。
/// 单轴产物返回 1 组，both 产物按索引顺序（水平、垂直）返回 2 组。
Future<List<InteractionFrameSet>> loadInteractionSets(String dir) async {
  final jsonBytes = await io.File('$dir/index.json').readAsBytes();
  return loadInteractionSetsFromIndexJson(
    jsonBytes,
    loadFrame: (file) => io.File('$dir/$file').readAsBytes(),
  );
}

/// 从索引 JSON 字节 + 帧加载回调构建帧集（Web/自定义存储嵌入方无需
/// 落盘语义，只需提供按文件名取字节的回调）。
Future<List<InteractionFrameSet>> loadInteractionSetsFromIndexJson(
  Uint8List indexJsonBytes, {
  required Future<Uint8List> Function(String file) loadFrame,
}) async {
  final index =
      (convert.jsonDecode(convert.utf8.decode(indexJsonBytes)) as Map)
          .cast<String, dynamic>();
  if (index['kind'] != 'interactive') {
    throw ArgumentError('index.json kind 必须为 interactive，'
        'got ${index['kind']}');
  }
  final sets = <InteractionFrameSet>[];
  for (final rawSet in (index['sets'] as List)) {
    final s = (rawSet as Map).cast<String, dynamic>();
    final axis = InteractionAxis.values.firstWhere(
      (a) => a.name == s['axis'],
      orElse: () => throw ArgumentError('未知 axis: ${s['axis']}'),
    );
    final phases = [
      for (final p in (s['phases'] as List)) (p as num).toDouble(),
    ];
    final pngBytes = <Uint8List>[];
    for (final f in (s['frames'] as List)) {
      pngBytes.add(await loadFrame(f as String));
    }
    if (pngBytes.length != phases.length) {
      throw ArgumentError(
          '帧数 ${pngBytes.length} 与 phases 数 ${phases.length} 不一致');
    }
    sets.add(InteractionFrameSet(
      axis: axis,
      phases: phases,
      pngBytes: pngBytes,
    ));
  }
  return sets;
}
