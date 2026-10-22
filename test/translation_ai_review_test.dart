import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/ai/translation_exception.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart'
    show AiEndpointConfig;
import 'package:nexhub/core/novel/novel_review_manager.dart';
import 'package:nexhub/core/novel/novel_translation_manager.dart';
import 'package:nexhub/features/novel/domain/novel_ai_review_fixer.dart';
import 'package:nexhub/features/novel/domain/novel_ai_review_service.dart';

const _endpoints = <AiEndpointConfig>[
  AiEndpointConfig(baseUrl: 'http://test.local', apiKey: 'k', model: 'm'),
];

NovelChapterTranslation _chapter({
  int paragraphs = 3,
  bool withSources = true,
  String chapterId = 'c1',
}) =>
    NovelChapterTranslation(
      novelId: 'n1',
      chapterId: chapterId,
      chapterTitle: '第一章',
      lang: '中文',
      translations: <String>[for (var i = 0; i < paragraphs; i++) '译文$i'],
      sources: withSources
          ? <String>[for (var i = 0; i < paragraphs; i++) '原文$i。']
          : null,
      updatedAt: 1,
    );

/// 顺序回放预设 JSON 内容的假端点；可注入前 N 次请求失败。
class _ReviewAdapter implements HttpClientAdapter {
  _ReviewAdapter(this.responses, {this.failFirst = 0});

  final List<String> responses;
  int failFirst;

  final List<String> systems = <String>[];
  final List<String> users = <String>[];
  int _index = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = options.data as Map<String, dynamic>;
    final messages = data['messages'] as List<dynamic>;
    systems.add((messages.first as Map<dynamic, dynamic>)['content'] as String);
    users.add((messages.last as Map<dynamic, dynamic>)['content'] as String);
    if (failFirst > 0) {
      failFirst--;
      return _error();
    }
    final i = _index < responses.length ? _index : responses.length - 1;
    _index++;
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{'message': <String, dynamic>{'content': responses[i]}},
        ],
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  ResponseBody _error() => ResponseBody.fromString(
        jsonEncode(<String, dynamic>{
          'error': <String, dynamic>{'message': 'boom'},
        }),
        500,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nexhub_ai_review');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    for (final box in <String>[
      NovelReviewManager.boxName,
      NovelTranslationManager.boxName,
    ]) {
      if (Hive.isBoxOpen(box)) {
        await Hive.deleteBoxFromDisk(box);
      }
    }
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // 清理失败忽略。
    }
  });

  group('审查报告模型扩展', () {
    test('AI 发现往返保留 engine/suggestion/revision', () {
      const f = TranslationReviewFinding(
        type: 'mistranslation',
        chapterId: 'c1',
        chapterTitle: '第一章',
        paragraphIndex: 2,
        source: '原文',
        translation: '译文',
        detail: '语义相反',
        engine: 'ai',
        suggestion: '改为肯定语气',
        revision: '修订译文',
      );
      final back = TranslationReviewFinding.fromJson(
        jsonDecode(jsonEncode(f.toJson())) as Map<String, dynamic>,
      );
      expect(back.engine, 'ai');
      expect(back.suggestion, '改为肯定语气');
      expect(back.revision, '修订译文');
    });

    test('旧发现缺省 engine=local，建议与修订为空', () {
      final f = TranslationReviewFinding.fromJson(<String, dynamic>{
        'type': 'glossary',
        'chapterId': 'c1',
        'chapterTitle': '第一章',
        'paragraphIndex': 0,
        'source': '',
        'translation': 'x',
        'detail': 'd',
      });
      expect(f.engine, 'local');
      expect(f.suggestion, isEmpty);
      expect(f.revision, isEmpty);
    });

    test('报告往返保留 engine/partial，旧报告缺省 local/false', () {
      const r = TranslationReviewReport(
        novelId: 'n1',
        lang: '中文',
        novelTitle: '书',
        createdAt: 1,
        chaptersReviewed: 2,
        findings: <TranslationReviewFinding>[],
        truncated: false,
        engine: 'ai',
        partial: true,
      );
      final back = TranslationReviewReport.fromJson(
        jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
      );
      expect(back.engine, 'ai');
      expect(back.partial, isTrue);

      final legacy = TranslationReviewReport.fromJson(<String, dynamic>{
        'novelId': 'n1',
        'lang': 'zh',
        'novelTitle': '书',
        'createdAt': 1,
        'chaptersReviewed': 0,
        'findings': <dynamic>[],
        'truncated': false,
      });
      expect(legacy.engine, 'local');
      expect(legacy.partial, isFalse);
    });
  });

  group('AI 审校服务', () {
    test('未配置端点直接抛异常', () async {
      final service = NovelAiReviewService(
        dio: Dio()..httpClientAdapter = _ReviewAdapter(const <String>[]),
      );
      await expectLater(
        service.reviewChapters(
          chapters: <NovelChapterTranslation>[_chapter()],
          lang: '中文',
          endpoints: const <AiEndpointConfig>[],
        ),
        throwsA(isA<TranslationException>()),
      );
    });

    test('产出 AI 发现：定位、类型归一、建议与修订齐备', () async {
      final adapter = _ReviewAdapter(<String>[
        jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'index': 2,
            'type': 'mistranslation',
            'detail': '语义相反',
            'suggestion': '改为肯定语气',
            'revision': '修订后的完整译文',
          },
          <String, dynamic>{
            'index': 1,
            'type': '误译',
            'detail': '中文类型别名也应归一',
            'suggestion': 's',
            'revision': '',
          },
          <String, dynamic>{
            'index': 99,
            'type': 'mistranslation',
            'detail': '越界段落应丢弃',
            'suggestion': '',
            'revision': '',
          },
          <String, dynamic>{
            'index': 1,
            'type': 'unknown_kind',
            'detail': '未知类型应丢弃',
            'suggestion': '',
            'revision': '',
          },
        ]),
      ]);
      final service = NovelAiReviewService(dio: Dio()..httpClientAdapter = adapter);

      final outcome = await service.reviewChapters(
        chapters: <NovelChapterTranslation>[_chapter()],
        lang: '中文',
        endpoints: _endpoints,
      );

      expect(outcome.partial, isFalse);
      expect(outcome.findings, hasLength(2));
      final first = outcome.findings[0];
      expect(first.type, 'mistranslation');
      expect(first.engine, 'ai');
      expect(first.chapterId, 'c1');
      // AI 的 index 为 1 基段落号：段落2 → 段内 0 基下标 1。
      expect(first.paragraphIndex, 1);
      expect(first.source, '原文1。');
      expect(first.translation, '译文1');
      expect(first.suggestion, '改为肯定语气');
      expect(first.revision, '修订后的完整译文');
      expect(outcome.findings[1].type, 'mistranslation');
      expect(outcome.findings[1].paragraphIndex, 0);
    });

    test('旧缓存无原文的章节跳过（无请求）', () async {
      final adapter = _ReviewAdapter(const <String>['[]']);
      final service = NovelAiReviewService(dio: Dio()..httpClientAdapter = adapter);

      final outcome = await service.reviewChapters(
        chapters: <NovelChapterTranslation>[_chapter(withSources: false)],
        lang: '中文',
        endpoints: _endpoints,
      );

      expect(outcome.findings, isEmpty);
      expect(outcome.partial, isFalse);
      expect(adapter.users, isEmpty);
    });

    test('超过 16 段分块请求，后续块携带邻段上下文', () async {
      final adapter = _ReviewAdapter(const <String>['[]', '[]']);
      final service = NovelAiReviewService(dio: Dio()..httpClientAdapter = adapter);

      final outcome = await service.reviewChapters(
        chapters: <NovelChapterTranslation>[
          _chapter(paragraphs: 17),
        ],
        lang: '中文',
        endpoints: _endpoints,
      );

      expect(adapter.users, hasLength(2));
      expect(outcome.chunksTotal, 2);
      expect(outcome.chunksDone, 2);
      // 第二块首段（第 17 段）的邻段上下文为第 16 段原文+译文。
      expect(adapter.users[1], contains('【邻段上下文'));
      expect(adapter.users[1], contains('原文16。'));
      expect(adapter.users[1], contains('译文15'));
      // 第一块无邻段。
      expect(adapter.users[0], isNot(contains('【邻段上下文')));
    });

    test('单块失败重试一次后成功：不标记 partial', () async {
      final adapter = _ReviewAdapter(
        const <String>['[]'],
        failFirst: 1,
      );
      final service = NovelAiReviewService(dio: Dio()..httpClientAdapter = adapter);

      final outcome = await service.reviewChapters(
        chapters: <NovelChapterTranslation>[_chapter()],
        lang: '中文',
        endpoints: _endpoints,
      );

      expect(adapter.users, hasLength(2));
      expect(outcome.partial, isFalse);
      expect(outcome.findings, isEmpty);
    });

    test('重试仍失败：跳过该块并标记 partial，不中断其余块', () async {
      // 两章：第一章的块两次失败被跳过，第二章正常返回发现。
      final adapter = _ReviewAdapter(const <String>['[]'], failFirst: 2);
      final service = NovelAiReviewService(dio: Dio()..httpClientAdapter = adapter);

      final outcome = await service.reviewChapters(
        chapters: <NovelChapterTranslation>[
          _chapter(chapterId: 'c1'),
          _chapter(chapterId: 'c2'),
        ],
        lang: '中文',
        endpoints: _endpoints,
      );

      expect(outcome.partial, isTrue);
      expect(adapter.users, hasLength(3));
    });

    test('块输出非 JSON：跳过并标记 partial', () async {
      final adapter = _ReviewAdapter(const <String>['这不是JSON']);
      final service = NovelAiReviewService(dio: Dio()..httpClientAdapter = adapter);

      final outcome = await service.reviewChapters(
        chapters: <NovelChapterTranslation>[_chapter()],
        lang: '中文',
        endpoints: _endpoints,
      );

      expect(outcome.findings, isEmpty);
      expect(outcome.partial, isTrue);
    });

    test('进度回调按块推进', () async {
      final adapter = _ReviewAdapter(const <String>['[]', '[]']);
      final service = NovelAiReviewService(dio: Dio()..httpClientAdapter = adapter);

      final progress = <String>[];
      await service.reviewChapters(
        chapters: <NovelChapterTranslation>[_chapter(paragraphs: 17)],
        lang: '中文',
        endpoints: _endpoints,
        onProgress: (done, total) => progress.add('$done/$total'),
      );

      expect(progress, <String>['1/2', '2/2']);
    });
  });

  group('影子修订应用器', () {
    test('采纳修订写回对应段落，指纹与原文保留，更新时间推进', () {
      const chapter = NovelChapterTranslation(
        novelId: 'n1',
        chapterId: 'c1',
        chapterTitle: '第一章',
        lang: '中文',
        translations: <String>['a', 'b', 'c'],
        sources: <String>['S1', 'S2', 'S3'],
        fingerprint: 'fp1',
        updatedAt: 100,
      );
      final fixed = NovelAiReviewFixer.apply(
        chapter: chapter,
        accepted: const <TranslationReviewFinding>[
          TranslationReviewFinding(
            type: 'mistranslation',
            chapterId: 'c1',
            chapterTitle: '第一章',
            paragraphIndex: 1,
            source: 'S2',
            translation: 'b',
            detail: '',
            engine: 'ai',
            revision: 'B!',
          ),
        ],
      );
      expect(fixed.translations, <String>['a', 'B!', 'c']);
      expect(fixed.sources, chapter.sources);
      expect(fixed.fingerprint, 'fp1');
      expect(fixed.updatedAt, greaterThan(100));
    });

    test('忽略空修订、他章修订与越界修订', () {
      const chapter = NovelChapterTranslation(
        novelId: 'n1',
        chapterId: 'c1',
        chapterTitle: '第一章',
        lang: '中文',
        translations: <String>['a', 'b'],
        updatedAt: 1,
      );
      final fixed = NovelAiReviewFixer.apply(
        chapter: chapter,
        accepted: const <TranslationReviewFinding>[
          TranslationReviewFinding(
            type: 'mistranslation',
            chapterId: 'c1',
            chapterTitle: '第一章',
            paragraphIndex: 0,
            source: '',
            translation: '',
            detail: '',
            engine: 'ai',
            revision: '',
          ),
          TranslationReviewFinding(
            type: 'mistranslation',
            chapterId: 'c2',
            chapterTitle: '第二章',
            paragraphIndex: 0,
            source: '',
            translation: '',
            detail: '',
            engine: 'ai',
            revision: 'X',
          ),
          TranslationReviewFinding(
            type: 'mistranslation',
            chapterId: 'c1',
            chapterTitle: '第一章',
            paragraphIndex: 9,
            source: '',
            translation: '',
            detail: '',
            engine: 'ai',
            revision: 'Y',
          ),
        ],
      );
      expect(fixed.translations, <String>['a', 'b']);
    });
  });
}
