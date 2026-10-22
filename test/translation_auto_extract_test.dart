import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/glossary_extractor.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/ai/translation_feature_flags.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart'
    show AiEndpointConfig;
import 'package:nexhub/features/novel/domain/novel_translation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _EchoAdapter implements HttpClientAdapter {
  final List<String> systems = <String>[];

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
    final user = (messages.last as Map<dynamic, dynamic>)['content'] as String;
    final matches = RegExp(r'<<<\s*(\d+)\s*>>>').allMatches(user).toList();
    final buf = StringBuffer();
    for (var i = 0; i < matches.length; i++) {
      final end = i + 1 < matches.length ? matches[i + 1].start : user.length;
      buf.writeln('<<<${i + 1}>>>');
      buf.writeln('译:${user.substring(matches[i].end, end).trim()}');
    }
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{'content': buf.toString()},
          },
        ],
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

class _FakeExtractor extends GlossaryExtractor {
  _FakeExtractor(this.batches);

  final List<List<GlossaryEntry>> batches;
  final List<
      ({
        List<String> sources,
        List<String> translations,
        List<GlossaryEntry> existing,
      })> calls = <({
    List<String> sources,
    List<String> translations,
    List<GlossaryEntry> existing,
  })>[];
  int _index = 0;

  @override
  Future<List<GlossaryEntry>> extract({
    required List<AiEndpointConfig> endpoints,
    required String lang,
    required List<String> sources,
    required List<String> translations,
    List<GlossaryEntry> existing = const <GlossaryEntry>[],
  }) async {
    calls.add((
      sources: List<String>.of(sources),
      translations: List<String>.of(translations),
      existing: List<GlossaryEntry>.of(existing),
    ));
    final result = _index < batches.length
        ? batches[_index]
        : const <GlossaryEntry>[];
    _index++;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'novel_translation_api_base_v1': 'http://test.local',
      'translation_bing_enabled_v1': false,
    });
    await TranslationFeatureFlags.instance.reload();
    tempDir = await Directory.systemTemp.createTemp('nexhub_auto_extract');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    for (final name in <String>[
      GlossaryManager.boxName,
      GlossaryManager.conflictBoxName,
      GlossaryManager.metaBoxName,
    ]) {
      if (Hive.isBoxOpen(name)) {
        await Hive.deleteBoxFromDisk(name);
      }
    }
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // 清理失败忽略。
    }
  });

  test('分块翻译逐块提取；新术语立即进入下一块提示词', () async {
    final adapter = _EchoAdapter();
    final fake = _FakeExtractor(<List<GlossaryEntry>>[
      <GlossaryEntry>[
        const GlossaryEntry(
          id: '',
          term: '魔女',
          preferred: '女巫',
          type: 'person',
        ),
      ],
      const <GlossaryEntry>[],
    ]);
    final service = NovelTranslationService(
      dio: Dio()..httpClientAdapter = adapter,
      targetLanguage: '中文',
      extractor: fake,
    );
    final summaries = <GlossaryUpsertSummary>[];

    final result = await service.translateParagraphs(
      <String>['魔女が来た。', '魔女は笑う。', '魔女は去る。', '第四段。'],
      batchSize: 2,
      workId: 'book1',
      chapterId: 'c1',
      chapterTitle: '第一章',
      chapterIndex: 0,
      onGlossaryExtracted: summaries.add,
    );

    expect(result, hasLength(4));
    expect(fake.calls, hasLength(2));
    expect(fake.calls[0].sources, <String>['魔女が来た。', '魔女は笑う。']);
    expect(fake.calls[0].translations,
        <String>['译:魔女が来た。', '译:魔女は笑う。']);
    expect(fake.calls[0].existing, isEmpty);
    // 第一块提取的新词进入当前生效术语表；第二块原文出现该词即注入。
    expect(fake.calls[1].existing.any((e) => e.term == '魔女'), isTrue);
    expect(fake.calls[1].sources, <String>['魔女は去る。', '第四段。']);
    expect(adapter.systems, hasLength(2));
    expect(adapter.systems[1], contains('魔女→女巫'));

    expect(summaries, hasLength(1));
    expect(summaries.single.inserted, 1);
    expect(summaries.single.conflicts, 0);
    final stored = await GlossaryManager().entriesFor('book1', '中文');
    expect(stored.single.term, '魔女');
    expect(stored.single.preferred, '女巫');
    expect(stored.single.firstChapter, 0);
  });

  test('无作品 id 时不发提取请求', () async {
    final adapter = _EchoAdapter();
    final fake = _FakeExtractor(const <List<GlossaryEntry>>[]);
    final service = NovelTranslationService(
      dio: Dio()..httpClientAdapter = adapter,
      targetLanguage: '中文',
      extractor: fake,
    );
    await service.translateParagraphs(
      <String>['第一段。', '第二段。', '第三段。', '第四段。'],
      batchSize: 2,
    );
    expect(fake.calls, isEmpty);
    expect(adapter.systems, hasLength(2));
  });

  test('关闭自动提取后不发提取请求', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'novel_translation_api_base_v1': 'http://test.local',
      'translation_bing_enabled_v1': false,
      'translation_auto_extract_v1': '0',
    });
    await TranslationFeatureFlags.instance.reload();
    final adapter = _EchoAdapter();
    final fake = _FakeExtractor(const <List<GlossaryEntry>>[]);
    final service = NovelTranslationService(
      dio: Dio()..httpClientAdapter = adapter,
      targetLanguage: '中文',
      extractor: fake,
    );
    await service.translateParagraphs(
      <String>['第一段。', '第二段。', '第三段。'],
      batchSize: 2,
      workId: 'book1',
    );
    expect(fake.calls, isEmpty);
    expect(await GlossaryManager().entriesFor('book1', '中文'), isEmpty);
  });

  test('one-shot 整章成功后只提取一次', () async {
    final adapter = _EchoAdapter();
    final fake = _FakeExtractor(<List<GlossaryEntry>>[
      <GlossaryEntry>[
        const GlossaryEntry(
          id: '',
          term: '王都',
          preferred: '首都',
          type: 'place',
        ),
      ],
    ]);
    final service = NovelTranslationService(
      dio: Dio()..httpClientAdapter = adapter,
      targetLanguage: '中文',
      extractor: fake,
    );
    final summaries = <GlossaryUpsertSummary>[];
    final result = await service.translateParagraphs(
      <String>['王都へ行く。', '王都は遠い。'],
      workId: 'book1',
      onGlossaryExtracted: summaries.add,
    );
    expect(result, hasLength(2));
    expect(adapter.systems, hasLength(1));
    expect(fake.calls, hasLength(1));
    expect(fake.calls.single.sources,
        <String>['王都へ行く。', '王都は遠い。']);
    expect(summaries.single.inserted, 1);
    expect(
      (await GlossaryManager().entriesFor('book1', '中文')).single.type,
      'place',
    );
  });
}
