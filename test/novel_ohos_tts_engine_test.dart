/// 鸿蒙系统 TTS 桥（MethodChannel `nexhub/tts`）单测：
/// - init 只发一次，speak 携带文本与语速
/// - 原生 onComplete / onError 回调转发
/// - pause 退化为 stop；dispose 走 shutdown
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/novel/novel_tts_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('nexhub/tts');
  final List<MethodCall> calls = <MethodCall>[];

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls.clear();
    messenger().setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger().setMockMethodCallHandler(channel, null);
  });

  Future<void> nativeCall(String method, Object? arguments) async {
    await messenger().handlePlatformMessage(
      'nexhub/tts',
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, arguments)),
      (ByteData? _) {},
    );
  }

  test('init 只发一次，speak 携带文本与语速', () async {
    final engine = OhosTtsEngine();
    await engine.setLanguage('zh-CN');
    await engine.setSpeechRate(1.5);
    await engine.speak('第一段');
    await engine.speak('第二段');

    expect(
      calls.map((MethodCall call) => call.method),
      <String>['init', 'speak', 'speak'],
    );
    expect(calls[0].arguments, <String, Object?>{'language': 'zh-CN'});
    expect(
      calls[1].arguments,
      <String, Object?>{'text': '第一段', 'rate': 1.5},
    );

    await engine.dispose();
  });

  test('原生播放完成与错误回调转发到 Dart', () async {
    final engine = OhosTtsEngine();
    var completed = 0;
    String? error;
    engine.setCompletionHandler(() => completed++);
    engine.setErrorHandler((String message) => error = message);

    await nativeCall('onComplete', '');
    expect(completed, 1);

    await nativeCall('onError', '1002300005 engine failed');
    expect(error, '1002300005 engine failed');

    await engine.dispose();
  });

  test('pause 退化为 stop，dispose 关闭引擎', () async {
    final engine = OhosTtsEngine();
    await engine.pause();
    await engine.dispose();

    expect(
      calls.map((MethodCall call) => call.method),
      <String>['stop', 'shutdown'],
    );
  });

  test('init 失败通过错误回调上报且不抛出', () async {
    messenger().setMockMethodCallHandler(channel, (MethodCall call) async {
      throw PlatformException(code: 'tts_init_failed', message: 'no engine');
    });
    final engine = OhosTtsEngine();
    String? error;
    engine.setErrorHandler((String message) => error = message);

    await engine.speak('第一段');

    expect(error, 'no engine');
    await engine.dispose();
  });

  test('切换语种会重建引擎', () async {
    final engine = OhosTtsEngine();
    await engine.setLanguage('zh-CN');
    await engine.speak('中文');
    await engine.setLanguage('en-US');
    await engine.speak('English');

    expect(
      calls.map((MethodCall call) => call.method),
      <String>['init', 'speak', 'shutdown', 'init', 'speak'],
    );
    expect(calls[3].arguments, <String, Object?>{'language': 'en-US'});

    await engine.dispose();
  });
}
