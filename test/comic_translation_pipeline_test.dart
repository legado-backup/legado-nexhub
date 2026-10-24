/// 漫画翻译管线测试。
///
/// 用假的视觉客户端驱动四种关键路径：
/// - 快速路径一次通过 / 模型确认空页；
/// - 单条瑕疵时纠错请求失败 → 直接部分展示，不烧两阶段请求；
/// - 解析失败 → 纠错 → 纯 OCR → 按编号翻译 → 缺失编号定向重试；
/// - 拒答后 OCR 确认空页；OCR 失败且无可用结果时抛可读异常。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/ai/endpoint_router.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/ai/id_translation_protocol.dart';
import 'package:nexhub/core/ai/prompt_builder.dart';
import 'package:nexhub/core/ai/translation_exception.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart';
import 'package:nexhub/core/comic/comic_translation_manager.dart';
import 'package:nexhub/features/manga/domain/comic_translation_pipeline.dart';

typedef _VisionHandler = Future<VisionParseOutcome> Function(
  _FakeVisionClient client,
  String prompt,
  bool expectTranslation,
  String? correctionNote,
);

typedef _IdHandler = Future<IdTranslationParse> Function(
  _FakeVisionClient client,
  Map<int, String> sources,
  String? correctionNote,
);

class _FakeVisionClient extends VisionTranslationClient {
  _FakeVisionClient({required this.onVision, required this.onId});

  final _VisionHandler onVision;
  final _IdHandler onId;

  int visionCalls = 0;
  int idCalls = 0;
  final List<String?> idCorrectionNotes = <String?>[];

  @override
  Future<VisionParseOutcome> recognizeImageOutcome({
    required AiEndpointConfig config,
    required Uint8List imageBytes,
    required String mimeType,
    required String systemPrompt,
    bool expectTranslation = true,
    String? correctionNote,
    int? maxTokens,
    double temperature = 0.2,
    Duration receiveTimeout = const Duration(seconds: 180),
    int maxSide = 1600,
  }) {
    visionCalls++;
    return onVision(this, systemPrompt, expectTranslation, correctionNote);
  }

  @override
  Future<IdTranslationParse> translateSegmentsById({
    required AiEndpointConfig config,
    required String systemPrompt,
    required Map<int, String> sources,
    String? correctionNote,
    double temperature = 0.2,
    int? maxTokens,
    Duration receiveTimeout = const Duration(seconds: 120),
  }) {
    idCalls++;
    idCorrectionNotes.add(correctionNote);
    return onId(this, sources, correctionNote);
  }
}

const AiEndpointConfig _endpoint = AiEndpointConfig(
  baseUrl: 'https://fake.test/v1',
  apiKey: '',
  model: 'fake',
);

const VisionTextSegment _hello = VisionTextSegment(
  x1: 10,
  y1: 10,
  x2: 200,
  y2: 120,
  text: 'こんにちは',
  translation: '你好',
);

const VisionTextSegment _morning = VisionTextSegment(
  x1: 10,
  y1: 200,
  x2: 200,
  y2: 320,
  text: 'おはよう',
  translation: '早上好',
);

const VisionTextSegment _thanks = VisionTextSegment(
  x1: 10,
  y1: 600,
  x2: 200,
  y2: 720,
  text: 'ありがとう',
  translation: '谢谢',
);

VisionParseOutcome _ok(List<VisionTextSegment> segments) =>
    VisionParseOutcome(ok: true, segments: segments, raw: 'json');

VisionParseOutcome _bad(String raw) =>
    VisionParseOutcome(ok: false, segments: const <VisionTextSegment>[], raw: raw);

IdTranslationParse _ids(Map<int, String> translations) {
  final ids = translations.keys.toList()..sort();
  return IdTranslationParse(
    translations: translations,
    missingIds: const <int>[],
    duplicateIds: const <int>[],
    unknownIds: const <int>[],
    lineCount: ids.length,
  );
}

ComicTranslationRequest _request() => ComicTranslationRequest(
      endpoints: const <AiEndpointConfig>[_endpoint],
      imageBytes: Uint8List.fromList(<int>[1, 2, 3]),
      mimeType: 'image/png',
      targetLang: 'zh',
      glossary: const <GlossaryEntry>[],
      style: TranslationStyle.standard,
      contextPairs: const [],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AiEndpointRouter.resetHealth);

  test('快速路径一次通过：1 次请求、complete', () async {
    final client = _FakeVisionClient(
      onVision: (c, prompt, expectTranslation, note) async =>
          _ok(<VisionTextSegment>[_hello, _morning]),
      onId: (c, sources, note) async => _ids(const <int, String>{}),
    );
    final outcome =
        await ComicTranslationPipeline(client: client).translatePage(_request());
    expect(outcome.requests, 1);
    expect(outcome.status, ComicTranslationStatus.complete);
    expect(outcome.segments, hasLength(2));
    expect(outcome.translatedCount, 2);
    expect(client.idCalls, 0);
  });

  test('模型确认空页：返回 empty，不进入重试', () async {
    final client = _FakeVisionClient(
      onVision: (c, prompt, expectTranslation, note) async =>
          _ok(const <VisionTextSegment>[]),
      onId: (c, sources, note) async => _ids(const <int, String>{}),
    );
    final outcome =
        await ComicTranslationPipeline(client: client).translatePage(_request());
    expect(outcome.status, ComicTranslationStatus.empty);
    expect(outcome.requests, 1);
    expect(client.visionCalls, 1);
  });

  test('单条原文照抄 + 纠错请求失败：部分展示，不进入两阶段', () async {
    const echo = VisionTextSegment(
      x1: 10,
      y1: 800,
      x2: 200,
      y2: 900,
      text: 'こんにちは',
      translation: 'こんにちは',
    );
    final client = _FakeVisionClient(
      onVision: (c, prompt, expectTranslation, note) async {
        if (c.visionCalls == 2) {
          throw const TranslationException(
            '超时',
            kind: TranslationKind.timeout,
          );
        }
        return _ok(<VisionTextSegment>[_hello, _morning, _thanks, echo]);
      },
      onId: (c, sources, note) async => _ids(const <int, String>{}),
    );
    final outcome =
        await ComicTranslationPipeline(client: client).translatePage(_request());
    expect(outcome.status, ComicTranslationStatus.partial);
    expect(outcome.segments, hasLength(3));
    expect(outcome.segments.every((s) => s.translation.isNotEmpty), isTrue);
    expect(outcome.requests, 1);
    expect(client.idCalls, 0);
  });

  test('解析失败 → OCR → 编号翻译 → 缺失编号定向重试', () async {
    final client = _FakeVisionClient(
      onVision: (c, prompt, expectTranslation, note) async {
        if (expectTranslation) return _bad('抱歉，我无法翻译这张图片');
        return _ok(<VisionTextSegment>[
          const VisionTextSegment(
            x1: 10,
            y1: 10,
            x2: 200,
            y2: 120,
            text: 'こんにちは',
            translation: '',
          ),
          const VisionTextSegment(
            x1: 10,
            y1: 200,
            x2: 200,
            y2: 320,
            text: 'おはよう',
            translation: '',
          ),
        ]);
      },
      onId: (c, sources, note) async {
        if (c.idCalls == 1) {
          return _ids(<int, String>{1: '你好'});
        }
        expect(sources.keys, <int>[2]);
        expect(note, isNotNull);
        return _ids(<int, String>{2: '早上好'});
      },
    );
    final outcome =
        await ComicTranslationPipeline(client: client).translatePage(_request());
    expect(outcome.status, ComicTranslationStatus.complete);
    expect(outcome.segments, hasLength(2));
    expect(outcome.segments[0].translation, '你好');
    expect(outcome.segments[1].translation, '早上好');
    expect(outcome.requests, ComicTranslationPipeline.maxRequestsPerPage);
    expect(client.visionCalls, 3);
    expect(client.idCalls, 2);
  });

  test('视觉端拒答且 OCR 确认无文字：返回 empty', () async {
    final client = _FakeVisionClient(
      onVision: (c, prompt, expectTranslation, note) async {
        if (expectTranslation) return _bad('抱歉，我无法翻译这张图片');
        return _ok(const <VisionTextSegment>[]);
      },
      onId: (c, sources, note) async => _ids(const <int, String>{}),
    );
    final outcome =
        await ComicTranslationPipeline(client: client).translatePage(_request());
    expect(outcome.status, ComicTranslationStatus.empty);
    expect(outcome.requests, 3);
    expect(client.idCalls, 0);
  });

  test('纠错返回空数组不直接当空页：OCR 复核后继续翻译', () async {
    final client = _FakeVisionClient(
      onVision: (c, prompt, expectTranslation, note) async {
        if (expectTranslation) {
          return c.visionCalls == 1
              ? _bad('抱歉，我无法翻译这张图片')
              : _ok(const <VisionTextSegment>[]);
        }
        return _ok(const <VisionTextSegment>[
          VisionTextSegment(
            x1: 10,
            y1: 10,
            x2: 200,
            y2: 120,
            text: 'こんにちは',
            translation: '',
          ),
        ]);
      },
      onId: (c, sources, note) async => _ids(<int, String>{1: '你好'}),
    );
    final outcome =
        await ComicTranslationPipeline(client: client).translatePage(_request());
    expect(outcome.status, ComicTranslationStatus.complete);
    expect(outcome.segments.single.translation, '你好');
    expect(outcome.requests, 4);
    expect(client.visionCalls, 3);
    expect(client.idCalls, 1);
  });

  test('OCR 失败且无可用结果：抛 invalidResponse 可读异常', () async {
    final client = _FakeVisionClient(
      onVision: (c, prompt, expectTranslation, note) async {
        if (expectTranslation) return _bad('not json');
        throw const TranslationException('视觉服务不可用');
      },
      onId: (c, sources, note) async => _ids(const <int, String>{}),
    );
    await expectLater(
      ComicTranslationPipeline(client: client).translatePage(_request()),
      throwsA(
        isA<TranslationException>().having(
          (e) => e.kind,
          'kind',
          TranslationKind.invalidResponse,
        ),
      ),
    );
    expect(client.idCalls, 0);
  });

  test('两阶段翻译全失败时回退到快速路径的可用结果', () async {
    const echoHello = VisionTextSegment(
      x1: 10,
      y1: 800,
      x2: 200,
      y2: 900,
      text: 'こんにちは',
      translation: 'こんにちは',
    );
    const echoMorning = VisionTextSegment(
      x1: 10,
      y1: 950,
      x2: 200,
      y2: 980,
      text: 'おはよう',
      translation: 'おはよう',
    );
    final client = _FakeVisionClient(
      onVision: (c, prompt, expectTranslation, note) async {
        if (expectTranslation) {
          return _ok(
              <VisionTextSegment>[_hello, echoHello, echoMorning]);
        }
        return _ok(<VisionTextSegment>[
          const VisionTextSegment(
            x1: 10,
            y1: 10,
            x2: 200,
            y2: 120,
            text: 'こんにちは',
            translation: '',
          ),
          const VisionTextSegment(
            x1: 10,
            y1: 200,
            x2: 200,
            y2: 320,
            text: 'おはよう',
            translation: '',
          ),
        ]);
      },
      onId: (c, sources, note) async => _ids(const <int, String>{}),
    );
    final outcome =
        await ComicTranslationPipeline(client: client).translatePage(_request());
    expect(outcome.status, ComicTranslationStatus.partial);
    expect(outcome.segments, hasLength(1));
    expect(outcome.segments.single.translation, '你好');
    expect(outcome.requests, ComicTranslationPipeline.maxRequestsPerPage);
  });
}
