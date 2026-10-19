import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/bing_translation_client.dart';
import 'package:nexhub/core/ai/translation_exception.dart';
import 'package:nexhub/core/ai/translation_feature_flags.dart';
import 'package:nexhub/features/novel/domain/novel_translation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final ResponseBody Function(RequestOptions options) respond;
  int bingCalls = 0;
  int aiCalls = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.host == 'edge.microsoft.com') {
      bingCalls++;
    } else {
      aiCalls++;
    }
    return respond(options);
  }
}

ResponseBody _bingOk(RequestOptions options) {
  final texts = (options.data as List).cast<String>();
  return ResponseBody.fromString(
    jsonEncode(<Map<String, dynamic>>[
      for (final t in texts)
        <String, dynamic>{
          'translations': <Map<String, dynamic>>[
            <String, dynamic>{'text': 'B:$t', 'to': 'zh-Hans'},
          ],
        },
    ]),
    200,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    },
  );
}

ResponseBody _aiOk(RequestOptions options) {
  final messages = (options.data as Map<String, dynamic>)['messages'] as List;
  final content = (messages.last as Map)['content'] as String;
  final count = RegExp(r'<<<').allMatches(content).length;
  final body = <String>[
    for (var i = 0; i < count; i++) '<<<${i + 1}>>>\nAI:$i',
  ].join('\n');
  return ResponseBody.fromString(
    jsonEncode(<String, dynamic>{
      'choices': <Map<String, dynamic>>[
        <String, dynamic>{
          'message': <String, dynamic>{'content': body},
        },
      ],
    }),
    200,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nexhub_bing_trans_test');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await TranslationFeatureFlags.instance.reload();
    BingTranslationClient.resetCircuitBreaker();
  });
  tearDown(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // 清理失败忽略。
    }
  });

  test('Bing 优先成功且无需 AI 配置', () async {
    final adapter = _Adapter((options) {
      if (options.uri.host == 'edge.microsoft.com') return _bingOk(options);
      return _aiOk(options);
    });
    final service = NovelTranslationService(
      dio: Dio()..httpClientAdapter = adapter,
      targetLanguage: '中文',
      bingClient: BingTranslationClient(
        dio: Dio()..httpClientAdapter = adapter,
        delay: (_) async {},
      ),
    );
    final result = await service.translateParagraphs(<String>['Hello', 'World']);
    expect(result, <String>['B:Hello', 'B:World']);
    expect(adapter.bingCalls, greaterThan(0));
    expect(adapter.aiCalls, 0);
  });

  test('Bing 失败后 AI 从剩余段落续跑', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'novel_overview_api_base_v1': 'https://ai.test/v1',
      'novel_overview_api_model_v1': 'gpt-test',
    });
    await TranslationFeatureFlags.instance.reload();
    final adapter = _Adapter((options) {
      if (options.uri.host == 'edge.microsoft.com') {
        return ResponseBody.fromString('', 400);
      }
      return _aiOk(options);
    });
    final service = NovelTranslationService(
      dio: Dio()..httpClientAdapter = adapter,
      bingClient: BingTranslationClient(
        dio: Dio()..httpClientAdapter = adapter,
        delay: (_) async {},
      ),
    );
    final result = await service.translateParagraphs(<String>['Hello', 'World']);
    expect(result, <String>['AI:0', 'AI:1']);
    expect(adapter.aiCalls, 1);
  });

  test('关闭 Bing 后纯 AI', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'translation_bing_enabled_v1': false,
      'novel_overview_api_base_v1': 'https://ai.test/v1',
      'novel_overview_api_model_v1': 'gpt-test',
    });
    await TranslationFeatureFlags.instance.reload();
    final adapter = _Adapter(_aiOk);
    final service = NovelTranslationService(
      dio: Dio()..httpClientAdapter = adapter,
      bingClient: BingTranslationClient(
        dio: Dio()..httpClientAdapter = adapter,
        delay: (_) async {},
      ),
    );
    final result = await service.translateParagraphs(<String>['Hello']);
    expect(result, <String>['AI:0']);
    expect(adapter.bingCalls, 0);
  });

  test('两侧都不可用抛明确文案', () async {
    final adapter = _Adapter((options) {
      if (options.uri.host == 'edge.microsoft.com') {
        return ResponseBody.fromString('', 400);
      }
      return ResponseBody.fromString('', 500);
    });
    final service = NovelTranslationService(
      dio: Dio()..httpClientAdapter = adapter,
      bingClient: BingTranslationClient(
        dio: Dio()..httpClientAdapter = adapter,
        delay: (_) async {},
      ),
    );
    await expectLater(
      service.translateParagraphs(<String>['Hello']),
      throwsA(isA<TranslationException>()),
    );
  });
}
