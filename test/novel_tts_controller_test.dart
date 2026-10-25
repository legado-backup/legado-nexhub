/// TTS 控制器单测（假系统引擎，逐句播放 + 声音路由 + 跨章续读）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/novel/novel_tts_cast_store.dart';
import 'package:nexhub/core/novel/novel_tts_engine.dart';
import 'package:nexhub/core/novel/novel_tts_router.dart';
import 'package:nexhub/features/novel/presentation/novel_tts_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假系统引擎：记录 speak 文本与 setVoice 调用；完成事件由测试手动触发
/// （[finishCurrent] 模拟一句播完）。
class _FakeEngine implements NovelTtsEngine {
  final List<String> spoken = <String>[];
  final List<String?> voiceBeforeSpeak = <String?>[];
  final List<NovelTtsVoice> voices;

  _FakeEngine({this.voices = const <NovelTtsVoice>[]});

  String? currentVoice;
  void Function()? onComplete;
  int speakCalls = 0;

  /// 模拟当前句播完（触发完成回调链）。
  Future<void> finishCurrent() async {
    final cb = onComplete;
    if (cb == null) return;
    cb();
    // 完成回调内部走 Future.microtask 推进下一句，让出一轮事件循环。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  void setCompletionHandler(void Function() handler) => onComplete = handler;

  @override
  void setErrorHandler(void Function(String message) handler) {}

  @override
  Future<void> setLanguage(String language) async {}

  @override
  Future<void> setSpeechRate(double rate) async {}

  @override
  Future<void> speak(String text) async {
    speakCalls++;
    spoken.add(text);
    voiceBeforeSpeak.add(currentVoice);
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<List<NovelTtsVoice>> getVoices() async => voices;

  @override
  Future<bool> setVoice(NovelTtsVoice? voice) async {
    currentVoice = voice?.name;
    return voice != null;
  }
}

Future<void> _pump([int times = 3]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('tts_ctrl_test_');
    Hive.init(tmpDir.path);
  });

  tearDown(() async {
    await Hive.close();
    await tmpDir.delete(recursive: true);
  });

  test('系统链路逐句朗读：旁白/对白按分句器切分，声音按路由切换', () async {
    await NovelTtsCastStore.instance.upsert('n1', '小明',
        gender: NovelCastGender.male, systemVoiceName: 'zh-male-1');
    final engine = _FakeEngine(voices: const [
      NovelTtsVoice(name: 'zh-male-1', locale: 'zh-CN'),
      NovelTtsVoice(name: 'zh-female-1', locale: 'zh-CN'),
    ]);
    final controller = NovelTtsController(engineFactory: () => engine);

    await controller.speak(
      <String>['天亮了。小明说：你好。'],
      novelId: 'n1',
      systemSlots: const NovelTtsSystemSlots(
          narrator: 'zh-female-1', female: 'zh-female-1'),
    );
    await _pump(5);

    // 逐句而非整段：先播旁白句。
    expect(engine.spoken, isNot(contains('天亮了。小明说：你好。')));
    expect(engine.spoken, <String>['天亮了。']);
    expect(engine.voiceBeforeSpeak.first, 'zh-female-1'); // 旁白槽
    expect(controller.state, NovelTtsState.playing);

    // 旁白句播完 → 对白句（角色绑定声音）。
    await engine.finishCurrent();
    await _pump(5);
    expect(engine.spoken, <String>['天亮了。', '你好。']);
    expect(engine.voiceBeforeSpeak.last, 'zh-male-1');

    // 对白句播完 → 章末（未开跨章）停止。
    await engine.finishCurrent();
    await _pump(5);
    expect(controller.state, NovelTtsState.stopped);
    controller.dispose();
  });

  test('跨章连播：章末回调翻章续读；关闭时章末停止', () async {
    final engine = _FakeEngine();
    final controller = NovelTtsController(engineFactory: () => engine);
    var chapterFinished = 0;
    controller.onChapterFinished = () async {
      chapterFinished++;
      // 阅读器语义：加载下一章后继续 speak。
      await controller.speak(<String>['第二章。'], autoNextChapter: false);
    };

    await controller.speak(<String>['第一章。'], autoNextChapter: true);
    await _pump(5);
    expect(controller.state, NovelTtsState.playing);

    await engine.finishCurrent(); // 第一章唯一句播完
    await _pump(8);
    expect(chapterFinished, 1);
    // 续章已开始朗读（autoNext 关闭 → 第二章末将停止）。
    expect(engine.spoken.last, '第二章。');
    expect(controller.state, NovelTtsState.playing);

    await engine.finishCurrent(); // 第二章播完 → 停止（无回调）
    await _pump(8);
    expect(chapterFinished, 1);
    expect(controller.state, NovelTtsState.stopped);
    controller.dispose();
  });

  test('stop 立即中断：后续完成事件不再推进', () async {
    final engine = _FakeEngine();
    final controller = NovelTtsController(engineFactory: () => engine);
    await controller.speak(<String>['第一句。第二句。']);
    await _pump(5);
    final count = engine.spoken.length;

    await controller.stop();
    await engine.finishCurrent();
    await _pump(5);
    expect(engine.spoken.length, count);
    expect(controller.state, NovelTtsState.stopped);
    controller.dispose();
  });
}
