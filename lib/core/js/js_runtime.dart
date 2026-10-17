/// JS 沙箱运行时统一接口。
///
/// 目的：书源 JS（ScriptResolver / JsContext）不直接绑死 flutter_js——
/// Android / iOS / 桌面继续用 flutter_js（QuickJS / JavaScriptCore），
/// 鸿蒙用随 HAP 打包的 QuickJS 原生桥（dart:ffi，见 third_party/quickjs_bridge）。
library;

/// 一次 evaluate 的结果（对齐 flutter_js JsEvalResult 的所用字段子集）。
class NexJsEvalResult {
  const NexJsEvalResult(
    this.stringResult, {
    this.isError = false,
    this.isPromise,
    this.raw,
  });

  /// 结果字符串；[isError] 为 true 时是错误信息。
  final String stringResult;

  /// 脚本是否抛异常。
  final bool isError;

  /// 结果是否为未落地的 Promise。null = 该平台无法识别（按 false 处理）。
  final bool? isPromise;

  /// 具体实现的原始结果对象（如 flutter_js 的 JsEvalResult，含内部句柄，
  /// [handlePromise] 需要它）。跨实现不可解读，仅透传。
  final Object? raw;
}

/// JS 运行时能力集合（同步求值 / 异步求值 / Promise 落地 / 桥接消息订阅）。
abstract interface class NexJsRuntime {
  /// 同步执行 [code]。
  NexJsEvalResult evaluate(String code);

  /// 异步语义执行。桌面/安卓为 flutter_js 的 evaluateAsync（内部 await Promise）；
  /// 鸿蒙为同步执行 + 原生微任务泵（结果为字符串形态，Promise 场景由调用方轮询）。
  Future<NexJsEvalResult> evaluateAsync(String code);

  /// 等待 [promise] 结果落地。不支持该能力的平台抛 [UnsupportedError]，
  /// 调用方按既定策略降级（Phase3-C 轮询全局变量）。
  Future<NexJsEvalResult> handlePromise(
    NexJsEvalResult promise, {
    Duration timeout = const Duration(seconds: 15),
  });

  /// 订阅 JS 侧 `sendMessage(channel, payload)`。
  void onMessage(String channel, void Function(dynamic message) handler);

  void dispose();
}
