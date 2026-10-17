import 'package:flutter_js/flutter_js.dart';

import 'js_runtime.dart';

/// flutter_js 实现（Android / iOS / Windows / Linux / macOS）。
///
/// 行为与改造前完全一致：构造时启用 Promise 处理（书源脚本大量 `await
/// ctx.http.get(...)`，未启用时 evaluateAsync 不 await，返回值恒为空）。
class FlutterJsRuntime implements NexJsRuntime {
  FlutterJsRuntime() {
    _runtime.enableHandlePromises();
  }

  final JavascriptRuntime _runtime = getJavascriptRuntime();

  @override
  NexJsEvalResult evaluate(String code) => _wrap(_runtime.evaluate(code));

  @override
  Future<NexJsEvalResult> evaluateAsync(String code) async =>
      _wrap(await _runtime.evaluateAsync(code));

  @override
  Future<NexJsEvalResult> handlePromise(
    NexJsEvalResult promise, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final raw = promise.raw;
    if (raw is! JsEvalResult) {
      throw UnsupportedError('handlePromise 需要 flutter_js 的原始结果对象');
    }
    return _wrap(await _runtime.handlePromise(raw, timeout: timeout));
  }

  @override
  void onMessage(String channel, void Function(dynamic message) handler) {
    _runtime.onMessage(channel, handler);
  }

  @override
  void dispose() => _runtime.dispose();

  static NexJsEvalResult _wrap(JsEvalResult r) => NexJsEvalResult(
        r.stringResult,
        isError: r.isError,
        isPromise: r.isPromise,
        raw: r,
      );
}
