/// 在线多音色 TTS 单测：
/// - 分句器（cue 判角色 / 引号配对 / 旁白切句 / 性别推断）
/// - URL 模板渲染（{text}/{voice}/{rate} 占位符）
/// - 配置模型（round-trip 含三槽 / 角色音色映射 / 并发 clamp / 旧版兼容）
/// - 合成引擎（文件缓存命中 / 缓存键含音色语速 / 网络异常安全）
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/novel/novel_http_tts_config.dart';
import 'package:nexhub/core/novel/novel_http_tts_engine.dart';
import 'package:nexhub/core/novel/novel_speech_segmenter.dart';
import 'package:nexhub/core/novel/novel_tts_audio_cache.dart';

void main() {
  group('分句器：cue 判角色', () {
    test('冒号句式判角色', () {
      final segs = segmentSpeech('小明说：你好。');
      expect(segs.length, 1);
      expect(segs.first.role, '小明');
      expect(segs.first.text, '你好。');
    });

    test('「XX说道」判角色', () {
      final segs = segmentSpeech('小红说道："真的吗？"');
      expect(segs.length, 1);
      expect(segs.first.role, '小红');
    });

    test('无 cue 引号归属对话角色', () {
      final segs = segmentSpeech('"？？"');
      expect(segs.length, 1);
      expect(segs.last.role, quoteRole);
    });

    test('纯旁白按标点切句', () {
      final segs = segmentSpeech('天亮了。他走出门。');
      expect(segs.length, 2);
      expect(segs.every((s) => s.role == narratorRole), isTrue);
    });
  });

  group('分句器：混合段落', () {
    test('旁白+对话交错', () {
      final segs = segmentSpeech('他推开门。李四喊："进来吧。" 屋里很安静。');
      expect(segs.length, 3);
      expect(segs[1].role, '李四');
    });

    test('空段返回空列表', () {
      expect(segmentSpeech(''), isEmpty);
      expect(segmentSpeech('   '), isEmpty);
    });
  });

  group('分句器：性别推断', () {
    test('角色卡已知性别优先', () {
      final segs = segmentSpeech('小明说：你好。',
          knownGenders: const {'小明': SpeechGender.female});
      expect(segs.first.gender, SpeechGender.female);
    });

    test('代词句式「她说」判女声', () {
      final segs = segmentSpeech('她说："走吧。"');
      expect(segs.last.gender, SpeechGender.female);
    });

    test('代词句式「他问道」判男声', () {
      final segs = segmentSpeech('他问道："去哪？"');
      expect(segs.last.gender, SpeechGender.male);
    });

    test('称谓词判性别：姑娘→女 / 公子→男', () {
      expect(segmentSpeech('姑娘说道："请进。"').last.gender, SpeechGender.female);
      expect(segmentSpeech('公子笑道："好。"').last.gender, SpeechGender.male);
    });

    test('说话人名本身是称谓也能判', () {
      final segs = segmentSpeech('老奶奶说：当心。');
      expect(segs.first.gender, SpeechGender.female);
    });

    test('两性称谓同时命中判 unknown', () {
      final segs = segmentSpeech('姐姐和公子说道："一起来。"');
      expect(segs.last.gender, SpeechGender.unknown);
    });

    test('无线索对话 gender 为 unknown', () {
      expect(segmentSpeech('"？？"').last.gender, SpeechGender.unknown);
    });
  });

  group('URL 模板渲染', () {
    test('全占位符替换', () {
      final url = renderUrl(
        template: 'https://x.com/api?text={text}&voice={voice}&rate={rate}',
        text: '你好',
        voice: 'v1',
        rate: 1.5,
      );
      expect(url, contains('text=${Uri.encodeQueryComponent('你好')}'));
      expect(url, contains('voice=v1'));
      expect(url, contains('rate=1.5'));
    });

    test('空模板返回空串', () {
      expect(renderUrl(template: '', text: 'x'), '');
    });

    test('中文文本 URL 编码不破坏端点', () {
      final url = renderUrl(template: 'https://x.com?t={text}', text: '中文？&=');
      expect(Uri.tryParse(url), isNotNull);
    });
  });

  group('配置模型', () {
    test('round-trip 保留字段（含三槽）', () {
      const cfg = NovelHttpTtsConfig(
        enabled: true,
        urlTemplate: 'https://x/{text}',
        defaultVoice: 'd',
        narratorVoice: 'n',
        maleVoice: 'm',
        femaleVoice: 'f',
        voiceByRole: <String, String>{'小明': 'xm'},
        concurrency: 3,
        maxConsecutiveFailures: 5,
        silentPlaceholderOnFailure: false,
      );
      final restored = NovelHttpTtsConfig.fromJson(cfg.toJson());
      expect(restored.narratorVoice, 'n');
      expect(restored.maleVoice, 'm');
      expect(restored.femaleVoice, 'f');
      expect(restored.voiceByRole['小明'], 'xm');
      expect(restored.concurrency, 3);
      expect(restored.silentPlaceholderOnFailure, isFalse);
    });

    test('旧版 JSON（无三槽字段）兼容为空', () {
      final restored = NovelHttpTtsConfig.fromJson(const <String, dynamic>{
        'enabled': true,
        'urlTemplate': 'https://x/{text}',
        'defaultVoice': 'd',
        'voiceByRole': <String, String>{},
      });
      expect(restored.narratorVoice, '');
      expect(restored.maleVoice, '');
      expect(restored.femaleVoice, '');
    });

    test('并发 clamp 1-8', () {
      final restored = NovelHttpTtsConfig.fromJson(const <String, dynamic>{
        'concurrency': 99,
      });
      expect(restored.concurrency, 8);
    });

    test('角色音色映射：命中取专属，未命中回退默认', () {
      const cfg = NovelHttpTtsConfig(
        defaultVoice: 'd',
        voiceByRole: <String, String>{'小明': 'xm'},
      );
      expect(cfg.voiceForRole('小明'), 'xm');
      expect(cfg.voiceForRole('别人'), 'd');
    });
  });

  group('合成引擎：缓存与网络', () {
    late Directory tmpDir;
    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('tts_cache_test_');
    });
    tearDown(() async {
      await tmpDir.delete(recursive: true);
    });

    test('网络成功写缓存；同音色同语速命中缓存不再请求；音色/语速变化重新请求',
        () async {
      final cache = TtsAudioFileCache(tmpDir);
      final fakeDio = Dio();
      fakeDio.httpClientAdapter = _BytesAdapter();
      var calls = 0;
      final engine = HttpTtsPreloader(
        config: const NovelHttpTtsConfig(
            urlTemplate: 'https://x.com/tts?text={text}&voice={voice}'),
        rate: 1.5,
        cache: cache,
        dioFactory: () {
          calls++;
          return fakeDio;
        },
      );

      final r1 = await engine.synthesize(text: '你好', voice: 'v1', role: '旁白');
      expect(r1.bytes, isNotNull);
      expect(calls, 1);

      final r2 = await engine.synthesize(text: '你好', voice: 'v1', role: '旁白');
      expect(r2.bytes, isNotNull);
      expect(calls, 1); // 缓存命中，未再发请求

      // 音色不同 → 缓存键不同 → 重新请求。
      await engine.synthesize(text: '你好', voice: 'v2', role: '旁白');
      expect(calls, 2);

      // 语速不同 → 缓存键不同。
      final engineSlow = HttpTtsPreloader(
        config: const NovelHttpTtsConfig(
            urlTemplate: 'https://x.com/tts?text={text}&voice={voice}'),
        rate: 0.8,
        cache: cache,
        dioFactory: () {
          calls++;
          return fakeDio;
        },
      );
      await engineSlow.synthesize(text: '你好', voice: 'v1', role: '旁白');
      expect(calls, 3);
    });

    test('网络异常返回 null 字节不抛出', () async {
      final failingDio = Dio();
      failingDio.httpClientAdapter = _ErrorAdapter();
      final engine = HttpTtsPreloader(
        config: const NovelHttpTtsConfig(urlTemplate: 'https://x.com/{text}'),
        dioFactory: () => failingDio,
      );
      final r = await engine.synthesize(text: 'x', voice: '', role: '旁白');
      expect(r.bytes, isNull);
    });
  });
}

/// 固定返回一段字节的 adapter。
class _BytesAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future? cancelFuture) async {
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    return ResponseBody.fromBytes(bytes, 200, headers: const <String, List<String>>{
      Headers.contentLengthHeader: <String>['4'],
    });
  }
}

/// 总是抛网络错误的 adapter。
class _ErrorAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future? cancelFuture) async {
    throw DioException.connectionError(
        requestOptions: options, reason: 'test error');
  }
}
