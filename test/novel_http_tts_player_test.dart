/// 在线 TTS 播放管线单测（滑动窗口版）：
/// - 分句 → 顺序播放
/// - 合成失败静音占位（跳过继续）
/// - 连续失败达阈值停止剩余
/// - 播放失败按同策略降级
/// - 动态角色 provider / 音色 resolver 在合成时刻生效
/// - 并发上限遵守配置
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/novel/novel_http_tts_config.dart';
import 'package:nexhub/core/novel/novel_http_tts_engine.dart';
import 'package:nexhub/core/novel/novel_http_tts_player.dart';

/// 可控假引擎：按文本注入成功/失败，记录合成调用（文本/音色/角色）与
/// 在飞并发峰值。
class _FakeEngine implements TtsSynthesisEngine {
  _FakeEngine({this.failTexts = const <String>{}});

  /// 命中即返回 null 字节的文本集合。
  final Set<String> failTexts;

  /// 每次合成的 (text, voice, role) 记录。
  final List<(String, String, String)> calls = <(String, String, String)>[];

  /// 合成前的钩子（测试里用来制造延迟/阻塞）。
  Future<void> Function()? beforeSynth;

  int _inFlight = 0;
  int peakInFlight = 0;

  @override
  Future<TtsSynthesisResult> synthesize({
    required String text,
    required String voice,
    required String role,
  }) async {
    calls.add((text, voice, role));
    _inFlight++;
    peakInFlight = _inFlight > peakInFlight ? _inFlight : peakInFlight;
    try {
      await beforeSynth?.call();
      final ok = !failTexts.contains(text);
      return TtsSynthesisResult(
        bytes: ok ? _audio(text) : null,
        role: role,
      );
    } finally {
      _inFlight--;
    }
  }
}

Uint8List _audio(String tag) => Uint8List.fromList(utf8.encode(tag));

void main() {
  const alwaysOkConfig = NovelHttpTtsConfig(
    enabled: true,
    urlTemplate: 'https://x.com?t={text}',
    silentPlaceholderOnFailure: true,
  );
  const noPlaceholderConfig = NovelHttpTtsConfig(
    enabled: true,
    urlTemplate: 'https://x.com?t={text}',
    silentPlaceholderOnFailure: false,
  );

  group('播放管线：分句 + 顺序播放', () {
    test('旁白+对话按角色切分并顺序播放', () async {
      final played = <String>[];
      final engine = _FakeEngine();
      final player = NovelHttpTtsPlayer(
        config: alwaysOkConfig,
        engine: engine,
        player: (bytes) async {
          played.add(utf8.decode(bytes));
          return true;
        },
      );
      var completed = false;
      player.onCompleted = () => completed = true;

      // 「他推开门。」→ 旁白；「小明说：你好。」→ 角色（冒号句式）。
      await player.speak(<String>['他推开门。小明说：你好。']);

      expect(played.length, 2);
      expect(completed, isTrue);
      // 引擎收到两次合成：旁白句 + 小明的对白。
      expect(engine.calls.length, 2);
      expect(engine.calls[0].$3, '旁白');
      expect(engine.calls[1].$3, '小明');
    });

    test('全旁白段落播放', () async {
      final played = <String>[];
      final engine = _FakeEngine();
      final player = NovelHttpTtsPlayer(
        config: alwaysOkConfig,
        engine: engine,
        player: (bytes) async {
          played.add(utf8.decode(bytes));
          return true;
        },
      );
      await player.speak(<String>['天亮了。']);
      expect(played.length, 1);
    });
  });

  group('播放管线：动态角色与音色', () {
    test('roleProvider 在合成时刻覆盖本地角色', () async {
      final engine = _FakeEngine();
      final player = NovelHttpTtsPlayer(
        config: alwaysOkConfig,
        engine: engine,
        player: (bytes) async => true,
      );
      await player.speak(
        <String>['小明说：你好。'],
        segmentProvider: (unit) => unit.segment.copyWith(role: 'AI 认出的角色'),
      );
      expect(engine.calls.single.$3, 'AI 认出的角色');
    });

    test('voiceResolver 收到角色与本地性别，解析结果进入合成', () async {
      final engine = _FakeEngine();
      final player = NovelHttpTtsPlayer(
        config: alwaysOkConfig,
        engine: engine,
        player: (bytes) async => true,
      );
      await player.speak(
        <String>['她说："走吧。"'],
        voiceResolver: (role, gender) => 'voice-$gender',
      );
      // 代词句式判女声 → voice-female。
      expect(engine.calls.last.$2, 'voice-female');
    });

    test('AI 归因中途生效：provider 状态变化影响后续句子', () async {
      final engine = _FakeEngine();
      var aiReady = false;
      final player = NovelHttpTtsPlayer(
        config: const NovelHttpTtsConfig(
          urlTemplate: 'https://x.com?t={text}',
          concurrency: 1, // 串行保证合成顺序可预测
          silentPlaceholderOnFailure: true,
        ),
        engine: engine,
        player: (bytes) async => true,
      );
      final TtsSegmentProvider provider = (unit) =>
          aiReady ? unit.segment.copyWith(role: 'AI 角色') : unit.segment;
      // 第一轮：AI 未就绪，两句都用本地角色。
      await player.speak(<String>['小明说：一。', '小明说：二。'],
          segmentProvider: provider);
      // 第二轮：AI 归因到位（provider 数据源切换），同一 provider 返回新角色。
      aiReady = true;
      await player.speak(<String>['小明说：三。'], segmentProvider: provider);
      expect(engine.calls.length, 3);
      expect(engine.calls[0].$3, '小明');
      expect(engine.calls[1].$3, '小明');
      expect(engine.calls[2].$3, 'AI 角色');
    });
  });

  group('播放管线：失败降级', () {
    test('单句失败 + 静音占位 → 跳过继续播放后续', () async {
      final played = <String>[];
      final engine = _FakeEngine(failTexts: {'第一句。'});
      final player = NovelHttpTtsPlayer(
        config: alwaysOkConfig,
        engine: engine,
        player: (bytes) async {
          played.add(utf8.decode(bytes));
          return true;
        },
      );
      await player.speak(<String>['第一句。第二句。']);
      expect(played, <String>['第二句。']);
    });

    test('全部失败 + 静音占位 → 不播放但正常完成', () async {
      final played = <int>[];
      final engine = _FakeEngine(failTexts: {'一。', '二。'});
      final player = NovelHttpTtsPlayer(
        config: alwaysOkConfig,
        engine: engine,
        player: (bytes) async {
          played.add(1);
          return true;
        },
      );
      var completed = false;
      player.onCompleted = () => completed = true;
      await player.speak(<String>['一。二。']);
      expect(played, isEmpty);
      expect(completed, isTrue);
    });

    test('失败 + 关闭占位 → 立即停止（后续不播放）', () async {
      final played = <String>[];
      final engine = _FakeEngine(failTexts: {'一。'});
      final player = NovelHttpTtsPlayer(
        config: noPlaceholderConfig,
        engine: engine,
        player: (bytes) async {
          played.add(utf8.decode(bytes));
          return true;
        },
      );
      var completed = false;
      player.onCompleted = () => completed = true;
      await player.speak(<String>['一。二。']);
      expect(played, isEmpty);
      expect(completed, isFalse); // 中途终止不触发完成回调
    });

    test('连续失败达阈值（静音占位开启）→ 终止剩余', () async {
      final played = <String>[];
      final engine = _FakeEngine(failTexts: {'一。', '二。', '三。', '四。'});
      final player = NovelHttpTtsPlayer(
        config: const NovelHttpTtsConfig(
          urlTemplate: 'https://x.com?t={text}',
          silentPlaceholderOnFailure: true,
          maxConsecutiveFailures: 3,
          concurrency: 1,
        ),
        engine: engine,
        player: (bytes) async {
          played.add(utf8.decode(bytes));
          return true;
        },
      );
      var completed = false;
      player.onCompleted = () => completed = true;
      await player.speak(<String>['一。二。三。四。']);
      expect(played, isEmpty);
      expect(completed, isFalse); // 连续 3 句失败后终止
    });
  });

  group('播放管线：并发与取消', () {
    test('在飞合成并发不超过配置上限', () async {
      final engine = _FakeEngine()
        ..beforeSynth = () async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        };
      final player = NovelHttpTtsPlayer(
        config: const NovelHttpTtsConfig(
          urlTemplate: 'https://x.com?t={text}',
          concurrency: 2,
          silentPlaceholderOnFailure: true,
        ),
        engine: engine,
        player: (bytes) async => true,
      );
      await player.speak(<String>['一。二。三。四。五。六。']);
      expect(engine.peakInFlight, lessThanOrEqualTo(2));
      expect(engine.calls.length, 6);
    });

    test('cancel 中断剩余播放', () async {
      final played = <String>[];
      final engine = _FakeEngine();
      final player = NovelHttpTtsPlayer(
        config: alwaysOkConfig,
        engine: engine,
        player: (bytes) async {
          played.add(utf8.decode(bytes));
          return true;
        },
      );
      await player.speak(<String>['第一句。']);
      expect(played.length, greaterThanOrEqualTo(1));

      // cancel 后再次 speak 应正常重置。
      player.cancel();
      final engine2 = _FakeEngine();
      final player2 = NovelHttpTtsPlayer(
        config: alwaysOkConfig,
        engine: engine2,
        player: (bytes) async {
          played.add(utf8.decode(bytes));
          return true;
        },
      );
      await player2.speak(<String>['重置。']);
      expect(played.last, '重置。');
    });
  });
}
