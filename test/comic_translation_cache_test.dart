/// 漫画翻译缓存与上下文测试。
///
/// - 缓存状态/版本/重试次数往返、图片 URL 校验、旧版空页缓存迁移；
/// - 导出/导入保留完整度与补译次数；
/// - 上下文收集只取最近 3 页、过滤不合格译文、按对数和字符预算裁剪。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart';
import 'package:nexhub/core/comic/comic_translation_manager.dart';
import 'package:nexhub/features/manga/domain/comic_context_builder.dart';

ComicPageTranslation _page({
  required String imageUrl,
  required List<VisionTextSegment> segments,
  ComicTranslationStatus status = ComicTranslationStatus.complete,
  int retries = 0,
  int updatedAt = 1,
}) =>
    ComicPageTranslation(
      imageUrl: imageUrl,
      lang: 'zh',
      segments: segments,
      updatedAt: updatedAt,
      status: status,
      retries: retries,
    );

VisionTextSegment _seg(String text, String translation, {int i = 0}) =>
    VisionTextSegment(
      x1: i,
      y1: i,
      x2: 100 + i,
      y2: 100 + i,
      text: text,
      translation: translation,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('漫画翻译缓存状态', () {
    late Directory tempDir;
    late Box<dynamic> box;
    late ComicTranslationManager manager;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nexhub_comic_cache');
      Hive.init(tempDir.path);
      box = await Hive.openBox<dynamic>(
        'comic_cache_${DateTime.now().microsecondsSinceEpoch}',
      );
      manager = ComicTranslationManager(box: box);
    });

    tearDown(() async {
      await box.close();
      try {
        await Hive.deleteBoxFromDisk(box.name);
      } on Object {
        // 清理失败忽略。
      }
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });

    test('JSON 往返保留 version/status/retries', () {
      final t = _page(
        imageUrl: 'https://img/1.jpg',
        segments: <VisionTextSegment>[_seg('原文', '译文')],
        status: ComicTranslationStatus.partial,
        retries: 1,
      );
      final restored = ComicPageTranslation.fromJson(t.toJson());
      expect(restored.version, ComicPageTranslation.currentVersion);
      expect(restored.status, ComicTranslationStatus.partial);
      expect(restored.retries, 1);
      expect(restored.translatedCount, 1);
    });

    test('图片 URL 不一致按未命中处理，一致时保留 partial 状态', () async {
      await manager.save(
        comicId: 'c1',
        chapterKey: 'ch1',
        pageIndex: 0,
        lang: 'zh',
        translation: _page(
          imageUrl: 'https://img/old.jpg',
          segments: <VisionTextSegment>[_seg('原文', '译文')],
          status: ComicTranslationStatus.partial,
          retries: 1,
        ),
      );
      expect(
        await manager.load(
          comicId: 'c1',
          chapterKey: 'ch1',
          pageIndex: 0,
          lang: 'zh',
          expectedImageUrl: 'https://img/new.jpg',
        ),
        isNull,
      );
      final hit = await manager.load(
        comicId: 'c1',
        chapterKey: 'ch1',
        pageIndex: 0,
        lang: 'zh',
        expectedImageUrl: 'https://img/old.jpg',
      );
      expect(hit, isNotNull);
      expect(hit!.status, ComicTranslationStatus.partial);
      expect(hit.retries, 1);
    });

    test('旧版空页缓存不可信；旧版非空缓存继续可用', () async {
      final key = ComicTranslationManager.keyFor(
        'c2',
        'ch1',
        0,
        lang: 'zh',
      );
      await box.put(
        key,
        jsonEncode(<String, dynamic>{
          'imageUrl': 'https://img/1.jpg',
          'lang': 'zh',
          'segments': <dynamic>[],
          'updatedAt': 1,
        }),
      );
      expect(
        await manager.load(
          comicId: 'c2',
          chapterKey: 'ch1',
          pageIndex: 0,
          lang: 'zh',
        ),
        isNull,
      );

      await box.put(
        key,
        jsonEncode(<String, dynamic>{
          'imageUrl': 'https://img/2.jpg',
          'lang': 'zh',
          'segments': <Map<String, dynamic>>[
            _seg('原文', '译文').toJson(),
          ],
          'updatedAt': 2,
        }),
      );
      final legacy = await manager.load(
        comicId: 'c2',
        chapterKey: 'ch1',
        pageIndex: 0,
        lang: 'zh',
      );
      expect(legacy, isNotNull);
      expect(legacy!.version, 0);
      expect(legacy.status, ComicTranslationStatus.complete);
    });

    test('导出→清空→导入保留 complete/partial 与 retries', () async {
      await manager.save(
        comicId: 'c3',
        chapterKey: 'ch1',
        pageIndex: 0,
        lang: 'zh',
        translation: _page(
          imageUrl: 'https://img/0.jpg',
          segments: <VisionTextSegment>[_seg('原文', '译文')],
        ),
      );
      await manager.save(
        comicId: 'c3',
        chapterKey: 'ch1',
        pageIndex: 1,
        lang: 'zh',
        translation: _page(
          imageUrl: 'https://img/1.jpg',
          segments: <VisionTextSegment>[_seg('原文', '译文')],
          status: ComicTranslationStatus.partial,
          retries: 2,
        ),
      );
      final json = await manager.exportJson();
      await manager.clearAll();
      final (imported, skipped) = await manager.importJson(json);
      expect(imported, 2);
      expect(skipped, 0);
      final partial = await manager.load(
        comicId: 'c3',
        chapterKey: 'ch1',
        pageIndex: 1,
        lang: 'zh',
      );
      expect(partial, isNotNull);
      expect(partial!.status, ComicTranslationStatus.partial);
      expect(partial.retries, 2);
    });
  });

  group('漫画上下文收集', () {
    late Directory tempDir;
    late Box<dynamic> box;
    late ComicTranslationManager manager;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nexhub_comic_ctx');
      Hive.init(tempDir.path);
      box = await Hive.openBox<dynamic>(
        'comic_ctx_${DateTime.now().microsecondsSinceEpoch}',
      );
      manager = ComicTranslationManager(box: box);
    });

    tearDown(() async {
      await box.close();
      try {
        await Hive.deleteBoxFromDisk(box.name);
      } on Object {
        // 清理失败忽略。
      }
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });

    test('只取最近 3 页，按从旧到新排序并裁剪到 32 对', () async {
      for (var page = 0; page < 5; page++) {
        await manager.save(
          comicId: 'c',
          chapterKey: 'ch',
          pageIndex: page,
          lang: 'zh',
          translation: _page(
            imageUrl: 'https://img/$page.jpg',
            segments: <VisionTextSegment>[
              for (var i = 0; i < 12; i++)
                _seg('台词${page}_$i', '译文${page}_$i', i: i),
            ],
          ),
        );
      }
      final pairs = await ComicContextBuilder.collect(
        manager: manager,
        comicId: 'c',
        chapterKey: 'ch',
        pageIndex: 5,
        lang: 'zh',
      );
      expect(pairs, hasLength(ComicContextBuilder.maxPairs));
      expect(pairs.first.source, '台词2_4');
      expect(pairs.last.source, '台词4_11');
    });

    test('过滤原文照抄/空译文，并按字符预算保留最近内容', () async {
      final long = '字' * 105;
      await manager.save(
        comicId: 'c',
        chapterKey: 'ch',
        pageIndex: 0,
        lang: 'zh',
        translation: _page(
          imageUrl: 'https://img/0.jpg',
          segments: <VisionTextSegment>[
            for (var i = 0; i < 12; i++)
              _seg('S$i$long', 'T$i$long', i: i),
          ],
        ),
      );
      await manager.save(
        comicId: 'c',
        chapterKey: 'ch',
        pageIndex: 1,
        lang: 'zh',
        translation: _page(
          imageUrl: 'https://img/1.jpg',
          segments: <VisionTextSegment>[
            _seg('正常原文', '正常译文'),
            _seg('照抄原文很长', '照抄原文很长'),
            _seg('空译文原文', ''),
          ],
        ),
      );
      final pairs = await ComicContextBuilder.collect(
        manager: manager,
        comicId: 'c',
        chapterKey: 'ch',
        pageIndex: 2,
        lang: 'zh',
      );
      // 上一页只保留 1 条合格对；再往前一页按字符预算裁剪。
      expect(pairs.map((p) => p.source), contains('正常原文'));
      final chars = pairs.fold<int>(
        0,
        (sum, p) => sum + p.source.length + p.translation.length,
      );
      expect(chars, lessThanOrEqualTo(ComicContextBuilder.maxChars));
      expect(
        pairs.where((p) => p.source == '照抄原文很长'),
        isEmpty,
      );
      expect(
        pairs.where((p) => p.source == '空译文原文'),
        isEmpty,
      );
      expect(pairs.last.source, '正常原文');
    });
  });
}
