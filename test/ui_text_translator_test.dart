import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/bing_translation_client.dart';
import 'package:nexhub/core/ai/text_translation_cache.dart';
import 'package:nexhub/core/ai/translation_exception.dart';
import 'package:nexhub/core/ai/translation_feature_flags.dart';
import 'package:nexhub/core/ai/ui_text_translator.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart';
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

ResponseBody _json(Object data, {int code = 200}) => ResponseBody.fromString(
      jsonEncode(data),
      code,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nexhub_ui_tr_test');
    Hive.init(tempDir.path);
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

  test('Bing 成功时批量聚合并写内存缓存', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await TranslationFeatureFlags.instance.reload();
    final adapter = _Adapter((options) {
      final texts = (options.data as List).cast<String>();
      return _json(<Map<String, dynamic>>[
        for (final t in texts)
          <String, dynamic>{
            'translations': <Map<String, dynamic>>[
              <String, dynamic>{'text': '译:$t', 'to': 'zh-Hans'},
            ],
          },
      ]);
    });
    final translator = UiTextTranslator(
      bing: BingTranslationClient(
          dio: Dio()..httpClientAdapter = adapter, delay: (_) async {}),
      cache: TextTranslationCache(),
    );
    final results = await Future.wait(<Future<String?>>[
      translator.translate('Title', targetLang: '中文'),
      translator.translate('Tag', targetLang: '中文'),
    ]);
    expect(results, <String?>['译:Title', '译:Tag']);
    expect(adapter.bingCalls, 1);
    expect(await translator.translate('Title', targetLang: '中文'), '译:Title');
    expect(adapter.bingCalls, 1);
  });

  test('Bing 失败时回落到 AI', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'novel_overview_api_base_v1': 'https://ai.test/v1',
      'novel_overview_api_model_v1': 'gpt-test',
    });
    await TranslationFeatureFlags.instance.reload();
    final adapter = _Adapter((options) {
      if (options.uri.host == 'edge.microsoft.com') {
        return ResponseBody.fromString('', 400);
      }
      final texts = BatchText.of(options);
      return _json(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{
              'content': <String>[
                for (var i = 0; i < texts.length; i++)
                  '<<<${i + 1}>>>\nAI:$i',
              ].join('\n'),
            },
          },
        ],
      });
    });
    final translator = UiTextTranslator(
      bing: BingTranslationClient(
          dio: Dio()..httpClientAdapter = adapter, delay: (_) async {}),
      aiClient: VisionTranslationClient(
          dio: Dio()..httpClientAdapter = adapter),
      cache: TextTranslationCache(),
    );
    final result = await translator.translate('Hello', targetLang: '中文');
    expect(result, 'AI:0');
    expect(adapter.aiCalls, 1);
  });

  test('两者都失败：自动返回 null，手动抛错', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await TranslationFeatureFlags.instance.reload();
    final adapter = _Adapter((_) => ResponseBody.fromString('', 400));
    final translator = UiTextTranslator(
      bing: BingTranslationClient(
          dio: Dio()..httpClientAdapter = adapter, delay: (_) async {}),
      cache: TextTranslationCache(),
    );
    expect(await translator.translate('Hello', targetLang: '中文'), isNull);
    await expectLater(
      translator.translate('Hello', targetLang: '中文', manual: true),
      throwsA(isA<TranslationException>()),
    );
  });

  test('同语言文本自动跳过', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await TranslationFeatureFlags.instance.reload();
    final adapter = _Adapter((_) => _json(<Map<String, dynamic>>[]));
    final translator = UiTextTranslator(
      bing: BingTranslationClient(
          dio: Dio()..httpClientAdapter = adapter, delay: (_) async {}),
      cache: TextTranslationCache(),
    );
    expect(await translator.translate('这是中文', targetLang: '中文'), isNull);
    expect(adapter.bingCalls, 0);
  });
}

abstract final class BatchText {
  static List<String> of(RequestOptions options) {
    final messages = (options.data as Map<String, dynamic>)['messages'] as List;
    final content = (messages.last as Map)['content'] as String;
    return RegExp(r'<<<\s*\d+\s*>>>\n?([^\n]*)')
        .allMatches(content)
        .map((m) => m.group(1) ?? '')
        .toList();
  }
}
