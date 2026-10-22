import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/ai/prompt_builder.dart';
import 'package:nexhub/core/ai/translation_options_store.dart';
import 'package:nexhub/features/novel/domain/novel_translation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 按提示词类型分流响应的假端点：小说翻译请求回「译低/中/高:原文」
///（按请求温度标注），精译合成请求回「合成:原文」；可按温度或次数注入失败。
class _RefinedAdapter implements HttpClientAdapter {
  _RefinedAdapter({
    this.failTemps = const <double>[],
    this.failSynthesis = false,
    this.failNextNovel = 0,
  });

  final List<double> failTemps;
  final bool failSynthesis;
  int failNextNovel;

  final List<double> novelTemps = <double>[];
  final List<int> novelParagraphCounts = <int>[];
  final List<String> synthesisUsers = <String>[];
  int synthesisCount = 0;

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
    final system =
        (messages.first as Map<dynamic, dynamic>)['content'] as String;
    final user = (messages.last as Map<dynamic, dynamic>)['content'] as String;
    final temp = (data['temperature'] as num).toDouble();

    if (system.contains('候选译文')) {
      synthesisCount++;
      synthesisUsers.add(user);
      if (failSynthesis) return _error();
      return _batchEcho(user.split('【候选译文').first, (s) => '合成:$s');
    }
    if (failNextNovel > 0) {
      failNextNovel--;
      return _error();
    }
    if (failTemps.contains(temp)) return _error();
    novelTemps.add(temp);
    novelParagraphCounts
        .add(RegExp(r'<<<\s*\d+\s*>>>').allMatches(user).length);
    final tag = temp <= 0.2 ? '低' : (temp <= 0.5 ? '中' : '高');
    return _batchEcho(user, (s) => '译$tag:$s');
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

  ResponseBody _batchEcho(String section, String Function(String) fn) {
    final matches = RegExp(r'<<<\s*\d+\s*>>>').allMatches(section).toList();
    final buf = StringBuffer();
    for (var i = 0; i < matches.length; i++) {
      final end =
          i + 1 < matches.length ? matches[i + 1].start : section.length;
      buf
        ..writeln('<<<${i + 1}>>>')
        ..writeln(fn(section.substring(matches[i].end, end).trim()));
    }
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{'message': <String, dynamic>{'content': buf.toString()}},
        ],
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nexhub_refined');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    if (Hive.isBoxOpen(GlossaryManager.boxName)) {
      await Hive.deleteBoxFromDisk(GlossaryManager.boxName);
    }
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // 清理失败忽略。
    }
  });

  group('精译开关', () {
    test('默认关闭，写入后可读回', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = TranslationOptionsStore();
      expect(await store.getRefinedEnabled(), isFalse);
      await store.setRefinedEnabled(true);
      expect(await store.getRefinedEnabled(), isTrue);
      await store.setRefinedEnabled(false);
      expect(await store.getRefinedEnabled(), isFalse);
    });
  });

  group('精译合成提示词', () {
    test('包含候选段、编号协议、段数、风格与术语', () {
      final p = PromptBuilder.refineSynthesisSystemPrompt(
        lang: '中文',
        paragraphCount: 2,
        draftCount: 3,
        glossary: const <GlossaryEntry>[
          GlossaryEntry(id: 'g1', term: 'アリス', preferred: '爱丽丝'),
        ],
        style: TranslationStyle.elegant,
      );
      expect(p, contains('候选译文一'));
      expect(p, contains('候选译文三'));
      expect(p, contains('<<<序号>>>'));
      expect(p, contains('2 段'));
      expect(p, contains('文雅'));
      expect(p, contains('アリス→爱丽丝'));
    });
  });

  group('精译流水线', () {
    NovelTranslationService serviceWith(_RefinedAdapter adapter) =>
        NovelTranslationService(
          dio: Dio()..httpClientAdapter = adapter,
          targetLanguage: '中文',
        );

    test('开启精译：三稿并发 + 合成，且不走整章 one-shot', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'novel_translation_api_base_v1': 'http://test.local',
        'translation_bing_enabled_v1': false,
        'translation_refined_v1': '1',
      });
      final adapter = _RefinedAdapter();
      final service = serviceWith(adapter);

      final result = await service.translateParagraphs(
        const <String>['第一段。', '第二段。'],
      );

      expect(result, <String>['合成:第一段。', '合成:第二段。']);
      expect(adapter.novelTemps, <double>[0.2, 0.5, 0.8]);
      expect(adapter.synthesisCount, 1);
      final syn = adapter.synthesisUsers.single;
      expect(syn, contains('【候选译文一】'));
      expect(syn, contains('【候选译文二】'));
      expect(syn, contains('【候选译文三】'));
      expect(syn, contains('译低:第一段。'));
      expect(syn, contains('译中:第一段。'));
      expect(syn, contains('译高:第一段。'));
      expect(syn, contains('第一段。'));
    });

    test('单稿失败：用剩余两稿合成', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'novel_translation_api_base_v1': 'http://test.local',
        'translation_bing_enabled_v1': false,
        'translation_refined_v1': '1',
      });
      final adapter = _RefinedAdapter(failTemps: <double>[0.5]);
      final service = serviceWith(adapter);

      final result = await service.translateParagraphs(
        const <String>['第一段。', '第二段。'],
      );

      expect(result, <String>['合成:第一段。', '合成:第二段。']);
      expect(adapter.novelTemps, <double>[0.2, 0.8]);
      final syn = adapter.synthesisUsers.single;
      expect(syn, contains('【候选译文一】'));
      expect(syn, contains('【候选译文二】'));
      expect(syn, isNot(contains('【候选译文三】')));
    });

    test('草稿全败：回落普通单译', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'novel_translation_api_base_v1': 'http://test.local',
        'translation_bing_enabled_v1': false,
        'translation_refined_v1': '1',
      });
      final adapter = _RefinedAdapter(failNextNovel: 3);
      final service = serviceWith(adapter);

      final result = await service.translateParagraphs(
        const <String>['第一段。', '第二段。'],
      );

      expect(result, <String>['译低:第一段。', '译低:第二段。']);
      expect(adapter.novelTemps, <double>[0.2]);
      expect(adapter.synthesisCount, 0);
    });

    test('合成失败：取第一稿', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'novel_translation_api_base_v1': 'http://test.local',
        'translation_bing_enabled_v1': false,
        'translation_refined_v1': '1',
      });
      final adapter = _RefinedAdapter(failSynthesis: true);
      final service = serviceWith(adapter);

      final result = await service.translateParagraphs(
        const <String>['第一段。', '第二段。'],
      );

      expect(result, <String>['译低:第一段。', '译低:第二段。']);
      expect(adapter.synthesisCount, 1);
      expect(adapter.novelTemps, <double>[0.2, 0.5, 0.8]);
    });

    test('仅剩一稿：直接采用不合成', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'novel_translation_api_base_v1': 'http://test.local',
        'translation_bing_enabled_v1': false,
        'translation_refined_v1': '1',
      });
      final adapter = _RefinedAdapter(failTemps: <double>[0.5, 0.8]);
      final service = serviceWith(adapter);

      final result = await service.translateParagraphs(
        const <String>['第一段。', '第二段。'],
      );

      expect(result, <String>['译低:第一段。', '译低:第二段。']);
      expect(adapter.novelTemps, <double>[0.2]);
      expect(adapter.synthesisCount, 0);
    });

    test('精译关闭：保持整章 one-shot 单请求', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'novel_translation_api_base_v1': 'http://test.local',
        'translation_bing_enabled_v1': false,
      });
      final adapter = _RefinedAdapter();
      final service = serviceWith(adapter);

      final result = await service.translateParagraphs(
        const <String>['第一段。', '第二段。'],
      );

      expect(result, <String>['译低:第一段。', '译低:第二段。']);
      expect(adapter.novelTemps, <double>[0.2]);
      expect(adapter.synthesisCount, 0);
    });

    test('精译块上限 8 段：大章按 8 段分块逐块三稿合成', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'novel_translation_api_base_v1': 'http://test.local',
        'translation_bing_enabled_v1': false,
        'translation_refined_v1': '1',
      });
      final adapter = _RefinedAdapter();
      final service = serviceWith(adapter);

      final paragraphs = <String>[
        for (var i = 1; i <= 10; i++) '第$i段。',
      ];
      final result = await service.translateParagraphs(
        paragraphs,
        batchSize: 20,
      );

      expect(
        result,
        <String>[for (var i = 1; i <= 10; i++) '合成:第$i段。'],
      );
      final counts = <int>[...adapter.novelParagraphCounts]..sort();
      expect(counts, <int>[2, 2, 2, 8, 8, 8]);
      expect(adapter.synthesisCount, 2);
    });
  });
}
