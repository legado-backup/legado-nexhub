import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/ai/endpoint_router.dart';
import 'package:nexhub/core/ai/glossary_extractor.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart'
    show AiEndpointConfig;

class _JsonAdapter implements HttpClientAdapter {
  _JsonAdapter(this.content, {this.status = 200});

  final String content;
  final int status;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (status != 200) {
      return ResponseBody.fromString('', status);
    }
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{'content': content},
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

  const endpoint = AiEndpointConfig(
    baseUrl: 'http://extract.test',
    apiKey: '',
    model: 'gpt-test',
  );

  setUp(AiEndpointRouter.resetHealth);

  test('提取请求包含原文译文对与相关已有术语，并容错解析围栏', () async {
    final adapter = _JsonAdapter('''
```json
[
  {"term":"アリス","translation":"爱丽丝","type":"人名","aliases":["艾莉丝"]},
  {"term":"魔法","translation":"法术","type":"术语"}
]
```
''');
    final extractor =
        GlossaryExtractor(dio: Dio()..httpClientAdapter = adapter);
    final result = await extractor.extract(
      endpoints: const <AiEndpointConfig>[endpoint],
      lang: '中文',
      sources: const <String>['アリスは魔法を使う。', '魔法の森へ行く。'],
      translations: const <String>['爱丽丝使用法术。', '前往魔法森林。'],
      existing: const <GlossaryEntry>[
        GlossaryEntry(id: 'g1', term: 'アリス', preferred: '爱丽丝'),
        GlossaryEntry(id: 'g2', term: '王都', preferred: '王都'),
      ],
    );

    expect(result, hasLength(2));
    expect(result.first.term, 'アリス');
    expect(result.first.preferred, '爱丽丝');
    expect(result.first.type, 'person');
    expect(result.first.aliases, contains('艾莉丝'));

    expect(adapter.requests, hasLength(1));
    final data = adapter.requests.single.data as Map<String, dynamic>;
    final messages = data['messages'] as List<dynamic>;
    final system = (messages.first as Map)['content'] as String;
    final user = (messages.last as Map)['content'] as String;
    expect(system, contains('术语'));
    expect(system, contains('translation 必须是本次译文中实际出现的译法'));
    expect(user, contains('原文：アリスは魔法を使う。'));
    expect(user, contains('译文：爱丽丝使用法术。'));
    expect(user, contains('アリス→爱丽丝'));
    // 本批原文未出现的已有术语不注入，避免提示词噪声。
    expect(user, isNot(contains('王都')));
  });

  test('解析兼容 target/source 字段与对象包装，并归一化类型', () {
    final parsed = GlossaryExtractor.parseCandidates(<String, dynamic>{
      'terms': <dynamic>[
        <String, dynamic>{
          'source': '王都',
          'target': '首都',
          'type': '地名',
          'alias': '王城、都城',
        },
        <String, dynamic>{
          '原文': '師匠',
          '译文': '师父',
          '类型': '称谓',
        },
      ],
    });
    expect(parsed, hasLength(2));
    expect(parsed[0].type, 'place');
    expect(parsed[0].aliases, <String>['王城', '都城']);
    expect(parsed[1].type, 'appellation');
  });

  test('单批最多 20 条，空词条与超长词条被跳过', () {
    final items = <Map<String, dynamic>>[
      for (var i = 0; i < 25; i++)
        <String, dynamic>{'term': '词$i', 'translation': '译$i'},
      <String, dynamic>{'term': '', 'translation': '空'},
      <String, dynamic>{'term': 'x' * 41, 'translation': '超长'},
    ];
    final parsed = GlossaryExtractor.parseCandidates(items);
    expect(parsed, hasLength(GlossaryExtractor.maxBatchEntries));
    expect(parsed.first.term, '词0');
    expect(parsed.last.term, '词19');
  });

  test('请求失败或段数不足时静默返回空', () async {
    final adapter = _JsonAdapter('', status: 500);
    final extractor =
        GlossaryExtractor(dio: Dio()..httpClientAdapter = adapter);
    final failed = await extractor.extract(
      endpoints: const <AiEndpointConfig>[endpoint],
      lang: '中文',
      sources: const <String>['一', '二'],
      translations: const <String>['one', 'two'],
    );
    expect(failed, isEmpty);

    final onlyOne = await extractor.extract(
      endpoints: const <AiEndpointConfig>[endpoint],
      lang: '中文',
      sources: const <String>['一'],
      translations: const <String>['one'],
    );
    expect(onlyOne, isEmpty);
    expect(adapter.requests, hasLength(1));
  });

  test('构造提示词包含断句与已有译名约束', () {
    final system = GlossaryExtractor.buildSystemPrompt('中文');
    expect(system, contains('人名、地名、组织'));
    expect(system, contains('最多输出 20 条'));
    expect(system, contains('不要自行发明更优译名'));
    final user = GlossaryExtractor.buildUserPrompt(
      lang: '中文',
      sources: const <String>['アリス'],
      translations: const <String>['爱丽丝'],
      existing: const <GlossaryEntry>[
        GlossaryEntry(id: 'g', term: 'アリス', preferred: '爱丽丝'),
      ],
    );
    expect(user, contains('<<<1>>>'));
    expect(user, contains('アリス→爱丽丝'));
  });
}
