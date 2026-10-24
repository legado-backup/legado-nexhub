import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:material_ui/material_ui.dart' show NavigatorState;

import '../../features/manga/presentation/comic_reader_screen.dart';
import '../../features/novel/presentation/novel_reader_screen.dart';
import '../../features/player/presentation/video_player_screen.dart';
import '../models/episode.dart';
import '../navigation/app_navigator.dart';
import '../navigation/app_page_route.dart';
import 'platform_service.dart';

/// 鸿蒙跨设备接续（流转）。
///
/// 源端：可接续页面（播放器 / 阅读器）通过 [attach] 注册快照回调；系统发起
/// 接续时原生反向调用 Dart 的 `getContinuationState`，取最近注册持有者的快照。
/// 接收端：原生把 want 中的快照暂存，冷启动由首帧后 [consumePending] 主动拉取，
/// 热启动由 `onContinuationRestore` 推送后拉取，随后按快照直接打开对应页面。
///
/// 快照只携带能重建页面所需的最小数据：内容标识 + 当前章节 + 位置。
/// 章节列表按窗口截取（[encodeChapterWindow]），避免超长目录撑爆 want。
/// 本地内容（本地文件 / 直链）不参与接续——对端没有同样的文件。
class HarmonyContinuation {
  HarmonyContinuation._();

  static const MethodChannel _channel = MethodChannel('nexhub/continuation');

  /// 章节窗口最大序列化字节数（want 参数有上限，留足余量）。
  static const int _maxChaptersBytes = 48 * 1024;

  static final Map<Object, Map<String, Object?>? Function()> _owners =
      <Object, Map<String, Object?>? Function()>{};

  static bool _initialized = false;
  static bool _active = false;

  /// 当前平台是否支持（仅鸿蒙）。
  static bool get supported => PlatformService.instance.isOHOS;

  /// 启动期注册原生回调；非鸿蒙 / 重复调用直接返回。
  static void initialize() {
    if (!supported || _initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_onNativeCall);
  }

  /// 注册一个可接续持有者，返回传给 [detach] 的 token。
  ///
  /// 后注册者优先（栈顶页面覆盖栈底页面），与 Navigator 的页面顺序一致。
  static Object attach(Map<String, Object?>? Function() snapshot) {
    final Object token = Object();
    _owners[token] = snapshot;
    unawaited(_syncActive());
    return token;
  }

  /// 注销持有者；无持有者时通知系统不再显示「可接续」。
  static void detach(Object token) {
    if (_owners.remove(token) != null) {
      unawaited(_syncActive());
    }
  }

  /// 冷启动首帧后由应用根调用：取走暂存的接续快照并跳转。
  static Future<void> consumePending() async {
    if (!supported) return;
    try {
      final String? raw =
          await _channel.invokeMethod<String>('getPendingContinuation');
      if (raw == null || raw.isEmpty) return;
      await _restoreWhenNavigable(raw);
    } on Object catch (e) {
      debugPrint('HarmonyContinuation.consumePending failed: $e');
    }
  }

  /// 当前快照（JSON）；无持有者返回 null（原生据此拒绝接续）。
  static String? currentSnapshotJson() {
    final List<Map<String, Object?>? Function()> providers = _owners.values
        .toList(growable: false)
        .reversed
        .toList(growable: false);
    for (final Map<String, Object?>? Function() provider in providers) {
      try {
        final Map<String, Object?>? snapshot = provider();
        if (snapshot != null && snapshot.isNotEmpty) {
          return jsonEncode(<String, Object?>{'v': 1, ...snapshot});
        }
      } on Object catch (e) {
        debugPrint('HarmonyContinuation snapshot failed: $e');
      }
    }
    return null;
  }

  /// 截取章节窗口用于快照。
  ///
  /// 以 [currentIndex] 为中心取 ±[radius] 章；序列化超过 [_maxChaptersBytes]
  /// 时从两端向中心收缩。返回的 [start] 是窗口首章在原列表中的下标，
  /// 接收端用 `chapterIndex - start` 还原当前章位置。
  static ({List<Map<String, dynamic>> items, int start})? encodeChapterWindow(
    List<Episode>? chapters,
    int currentIndex, {
    int radius = 40,
  }) {
    if (chapters == null || chapters.isEmpty) return null;
    final int center = currentIndex.clamp(0, chapters.length - 1);
    int start = (center - radius).clamp(0, chapters.length);
    int end = (center + radius + 1).clamp(0, chapters.length);
    List<Map<String, dynamic>> items = <Map<String, dynamic>>[
      for (int i = start; i < end; i++) chapters[i].toJson(),
    ];
    while (items.length > 1 &&
        jsonEncode(items).length > _maxChaptersBytes) {
      // 裁掉离当前章更远的一端，保证中心章始终在窗口内。
      if (center - start >= end - 1 - center) {
        start++;
      } else {
        end--;
      }
      items = <Map<String, dynamic>>[
        for (int i = start; i < end; i++) chapters[i].toJson(),
      ];
    }
    return (items: items, start: start);
  }

  static Future<Object?> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'getContinuationState':
        return currentSnapshotJson();
      case 'onContinuationRestore':
        await consumePending();
        return null;
      default:
        return null;
    }
  }

  static Future<void> _syncActive() async {
    if (!supported) return;
    final bool want = _owners.isNotEmpty;
    if (want == _active) return;
    _active = want;
    try {
      await _channel.invokeMethod<void>(
        'setContinuationActive',
        <String, Object?>{'active': want},
      );
    } on Object catch (e) {
      debugPrint('HarmonyContinuation.setActive($want) failed: $e');
    }
  }

  static Future<void> _restoreWhenNavigable(String raw) async {
    for (int i = 0; i < 20; i++) {
      if (AppNavigator.navigator != null) {
        _restore(raw);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    debugPrint('HarmonyContinuation: navigator not ready, drop restore');
  }

  static void _restore(String raw) {
    final NavigatorState? navigator = AppNavigator.navigator;
    if (navigator == null) return;
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(raw) as Map<String, dynamic>;
    } on Object catch (e) {
      debugPrint('HarmonyContinuation: bad payload: $e');
      return;
    }
    final String type = data['type'] as String? ?? '';
    final String title = data['title'] as String? ?? '';
    final String sourceId = data['sourceId'] as String? ?? '';
    final String contentId = data['contentId'] as String? ?? '';
    final String? detailUrl = data['detailUrl'] as String?;
    final String? coverUrl = data['coverUrl'] as String?;
    if (sourceId.isEmpty || contentId.isEmpty) return;

    final Episode? current = _episodeFrom(data['episode']);
    final int chapterIndex = (data['chapterIndex'] as num?)?.toInt() ?? 0;
    final int episodeStart = (data['episodeStart'] as num?)?.toInt() ?? 0;
    final List<Episode> window = _episodesFrom(data['episodes']);
    final List<Episode> chapters = window.isNotEmpty
        ? window
        : (current != null ? <Episode>[current] : const <Episode>[]);
    if (chapters.isEmpty) return;
    final int initialIndex = window.isNotEmpty
        ? (chapterIndex - episodeStart).clamp(0, chapters.length - 1)
        : 0;

    switch (type) {
      case 'video':
        navigator.push(AppPageRoute<void>(
          builder: (_) => VideoPlayerScreen(
            title: title,
            episode: chapters[initialIndex],
            sourceId: sourceId,
            itemId: contentId,
            episodes: window.isNotEmpty ? window : null,
            initialEpisodeIndex: window.isNotEmpty ? initialIndex : null,
            detailUrl: detailUrl,
            coverUrl: coverUrl,
            restoreProgress: false,
            initialPositionMs: (data['positionMs'] as num?)?.toInt(),
            initialPlaying: data['playing'] != false,
          ),
        ));
      case 'novel':
        navigator.push(AppPageRoute<void>(
          builder: (_) => NovelReaderScreen(
            novelId: contentId,
            title: title,
            sourceId: sourceId,
            chapters: chapters,
            initialChapterIndex: initialIndex,
            restoreProgress: false,
            initialPage: (data['page'] as num?)?.toInt(),
            initialCharOffset: (data['charOffset'] as num?)?.toInt(),
            detailUrl: detailUrl,
            coverUrl: coverUrl,
          ),
        ));
      case 'comic':
        navigator.push(AppPageRoute<void>(
          builder: (_) => ComicReaderScreen(
            comicId: contentId,
            title: title,
            sourceId: sourceId,
            chapters: chapters,
            initialChapterIndex: initialIndex,
            restoreProgress: false,
            initialPage: (data['page'] as num?)?.toInt(),
            detailUrl: detailUrl,
            coverUrl: coverUrl,
          ),
        ));
    }
  }

  static Episode? _episodeFrom(Object? value) {
    if (value is! Map) return null;
    try {
      return Episode.fromJson(value.cast<String, dynamic>());
    } on Object {
      return null;
    }
  }

  static List<Episode> _episodesFrom(Object? value) {
    if (value is! List) return const <Episode>[];
    final List<Episode> out = <Episode>[];
    for (final Object? item in value) {
      final Episode? ep = _episodeFrom(item);
      if (ep != null) out.add(ep);
    }
    return out;
  }
}
