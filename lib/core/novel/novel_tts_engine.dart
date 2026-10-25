/// 小说离线朗读引擎抽象。
///
/// 默认平台使用 flutter_tts；鸿蒙（OHOS）无 flutter_tts 实现，改走系统
/// CoreSpeechKit（`@hms.ai.textToSpeech`）的 MethodChannel 桥。
/// 只暴露控制器实际使用的接口，避免把两个 SDK 的差异泄漏到上层。
library;

import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../platform/platform_service.dart';

/// 朗读引擎统一接口。
abstract class NovelTtsEngine {
  /// 整段朗读完成回调（由控制器用于自动续读下一段）。
  void setCompletionHandler(void Function() handler);

  /// 朗读失败回调。实现方需保证不会把异常抛到事件循环。
  void setErrorHandler(void Function(String message) handler);

  Future<void> setLanguage(String language);

  Future<void> setSpeechRate(double rate);

  /// 开始朗读一段文本。返回时表示已提交给引擎，不等待播放完成。
  Future<void> speak(String text);

  Future<void> stop();

  /// 暂停。鸿蒙系统引擎无 pause，实现为停止；恢复时由控制器重读当前段。
  Future<void> pause();

  Future<void> dispose();

  /// 枚举可用声音（多角色朗读用）。引擎不支持时返回空列表。
  Future<List<NovelTtsVoice>> getVoices();

  /// 切换声音（null = 恢复引擎默认）。返回是否切换成功；不支持或名字
  /// 不存在返回 false，调用方保持默认声音继续朗读。
  Future<bool> setVoice(NovelTtsVoice? voice);
}

/// 引擎声音描述（Android 需 name+locale 组合唯一定位；Windows 按 name）。
class NovelTtsVoice {
  const NovelTtsVoice({required this.name, this.locale = ''});

  final String name;
  final String locale;

  @override
  String toString() => locale.isEmpty ? name : '$name ($locale)';
}

/// 按平台创建默认朗读引擎。
NovelTtsEngine createNovelTtsEngine() {
  if (PlatformService.instance.isOHOS) return OhosTtsEngine();
  return FlutterTtsEngine();
}

/// flutter_tts 实现（Android / iOS / 桌面）。
class FlutterTtsEngine implements NovelTtsEngine {
  FlutterTtsEngine() : _tts = FlutterTts();

  final FlutterTts _tts;

  @override
  void setCompletionHandler(void Function() handler) {
    _tts.setCompletionHandler(handler);
  }

  @override
  void setErrorHandler(void Function(String message) handler) {
    _tts.setErrorHandler((dynamic message) => handler('$message'));
  }

  @override
  Future<void> setLanguage(String language) => _tts.setLanguage(language);

  @override
  Future<void> setSpeechRate(double rate) => _tts.setSpeechRate(rate);

  @override
  Future<void> speak(String text) => _tts.speak(text);

  @override
  Future<void> stop() => _tts.stop();

  @override
  Future<void> pause() => _tts.pause();

  @override
  Future<void> dispose() async {
    await _tts.stop();
  }

  @override
  Future<List<NovelTtsVoice>> getVoices() async {
    try {
      final voices = await _tts.getVoices;
      return <NovelTtsVoice>[
        for (final v in voices)
          if (v is Map<dynamic, dynamic>)
            NovelTtsVoice(
              name: '${v['name'] ?? ''}',
              locale: '${v['locale'] ?? ''}',
            ),
      ]..removeWhere((v) => v.name.isEmpty);
    } on Object {
      // 部分平台未实现 getVoices：视为无多声音能力。
      return const <NovelTtsVoice>[];
    }
  }

  @override
  Future<bool> setVoice(NovelTtsVoice? voice) async {
    if (voice == null) return false;
    try {
      return await _tts.setVoice(<String, String>{
        'name': voice.name,
        if (voice.locale.isNotEmpty) 'locale': voice.locale,
      });
    } on Object {
      // 平台不支持或声音不存在：保持默认声音。
      return false;
    }
  }
}

/// 鸿蒙系统离线 TTS 实现。
///
/// 原生侧见 `ohos/entry/src/main/ets/plugins/OhosTtsPlugin.ets`：
/// 引擎只能整体停止，不能暂停，因此 [pause] 退化为 [stop]，控制器恢复时
/// 重读当前段落。
class OhosTtsEngine implements NovelTtsEngine {
  OhosTtsEngine() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const MethodChannel _channel = MethodChannel('nexhub/tts');

  String _language = 'zh-CN';
  double _rate = 1.0;
  bool _initialized = false;
  bool _disposed = false;
  void Function()? _onCompletion;
  void Function(String message)? _onError;

  @override
  void setCompletionHandler(void Function() handler) {
    _onCompletion = handler;
  }

  @override
  void setErrorHandler(void Function(String message) handler) {
    _onError = handler;
  }

  @override
  Future<void> setLanguage(String language) async {
    if (_language == language) return;
    _language = language;
    if (_initialized) {
      _initialized = false;
      await _invoke('shutdown');
    }
  }

  @override
  Future<void> setSpeechRate(double rate) async {
    _rate = rate;
  }

  @override
  Future<void> speak(String text) async {
    if (_disposed || text.isEmpty) return;
    if (!await _ensureInitialized()) return;
    try {
      await _channel.invokeMethod<void>('speak', <String, Object?>{
        'text': text,
        'rate': _rate,
      });
    } on PlatformException catch (e) {
      _reportError(e.message ?? e.code);
    } on MissingPluginException {
      _reportError('ohos_tts_unavailable');
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    await _invoke('stop');
  }

  @override
  Future<void> pause() => stop();

  /// 鸿蒙 CoreSpeechKit 单声音引擎：无声音枚举与切换能力。
  @override
  Future<List<NovelTtsVoice>> getVoices() async => const <NovelTtsVoice>[];

  @override
  Future<bool> setVoice(NovelTtsVoice? voice) async => false;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _invoke('shutdown');
    _channel.setMethodCallHandler(null);
  }

  Future<bool> _ensureInitialized() async {
    if (_initialized) return true;
    try {
      await _channel.invokeMethod<void>('init', <String, Object?>{
        'language': _language,
      });
      _initialized = true;
      return true;
    } on PlatformException catch (e) {
      _reportError(e.message ?? e.code);
    } on MissingPluginException {
      _reportError('ohos_tts_unavailable');
    }
    return false;
  }

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException {
      // 停止/销毁失败无需打断上层（引擎可能尚未创建）。
    } on MissingPluginException {
      // 非鸿蒙宿主（理论上不会走到）静默忽略。
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onComplete') {
      _onCompletion?.call();
    } else if (call.method == 'onError') {
      _reportError('${call.arguments ?? ''}');
    }
    return null;
  }

  void _reportError(String message) {
    if (_disposed) return;
    _onError?.call(message);
  }
}
