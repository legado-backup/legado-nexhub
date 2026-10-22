import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/features/novel/domain/novel_translation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 捕获 system prompt 并回声译文的适配器。
class _CaptureAdapter implements HttpClientAdapter {
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
    final matches =
        RegExp(r'<<<\s*(\d+)\s*>>>').allMatches(user).toList();
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nexhub_ctx_flow');
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

  test('分块请求注入前章尾部、前块译文与下一段原文', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'novel_translation_api_base_v1': 'http://test.local',
      'translation_bing_enabled_v1': false,
    });
    final adapter = _CaptureAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final service = NovelTranslationService(
      dio: dio,
      targetLanguage: '中文',
    );

    final result = await service.translateParagraphs(
      <String>['第一段。', '第二段。', '第三段。', '第四段。'],
      batchSize: 2,
      previousChapterContext: <({String source, String translation})>[
        (source: '前章末段原文', translation: '前章末段译文'),
      ],
    );

    expect(
      result,
      <String>['译:第一段。', '译:第二段。', '译:第三段。', '译:第四段。'],
    );
    expect(adapter.systems, hasLength(2));

    // 第一块：前章尾部 + 第二块开头原文；无本章前文、无更后 lookahead。
    expect(adapter.systems[0], contains('前章末段原文'));
    expect(adapter.systems[0], contains('前章末段译文'));
    expect(adapter.systems[0], contains('下一段原文'));
    expect(adapter.systems[0], contains('第三段。'));
    expect(adapter.systems[0], isNot(contains('原文：第一段。')));

    // 第二块：前块已译段落作为滚动上下文；章末无 lookahead。
    expect(adapter.systems[1], contains('前文译文'));
    expect(adapter.systems[1], contains('原文：第一段。'));
    expect(adapter.systems[1], contains('译文：译:第一段。'));
    expect(adapter.systems[1], contains('原文：第二段。'));
    expect(adapter.systems[1], isNot(contains('下一段原文')));
  });
}
