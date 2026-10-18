import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../utils/app_log.dart';
import 'js_runtime.dart';

// QuickJS 原生桥（third_party/quickjs_bridge，随 HAP 打包为 libnexhub_quickjs.so）。
//
// 语义与 flutter_js 的差异：
// - evaluateAsync 不会真正 await Promise：同步执行 + 每次求值后由原生侧泵空
//   微任务队列（.then/.catch 在此推进），Promise 场景由上层的轮询策略收敛；
// - 不支持 handlePromise（抛 UnsupportedError，上层降级到 Phase3-C 轮询）；
// - sendMessage(channel, payload) 会同步回调 Dart 并返回回调结果（fire-and-forget
//   场景返回 null 即可），因此 Dart 侧桥接回调里禁止再做重入求值。

typedef _BridgeNative = Pointer<Utf8> Function(
    IntPtr, Pointer<Utf8>, Pointer<Utf8>);
typedef _CreateNative = Pointer<Void> Function(
    Pointer<NativeFunction<_BridgeNative>>, IntPtr);
typedef _CreateDart = Pointer<Void> Function(
    Pointer<NativeFunction<_BridgeNative>>, int);
typedef _EvaluateNative = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, IntPtr, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>);
typedef _EvaluateDart = int Function(
    Pointer<Void>, Pointer<Utf8>, int, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>);

final Map<int, OhosJsRuntime> _runtimeById = <int, OhosJsRuntime>{};
int _nextRuntimeId = 1;

/// 原生 → Dart 的 sendMessage 回调（必须是顶层函数，供 Pointer.fromFunction）。
@pragma('vm:entry-point')
Pointer<Utf8> _dispatchBridge(
  int runtimeId,
  Pointer<Utf8> channel,
  Pointer<Utf8> payload,
) {
  final runtime = _runtimeById[runtimeId];
  if (runtime == null) {
    return 'null'.toNativeUtf8();
  }
  try {
    return runtime._handleBridge(
      channel.toDartString(),
      payload.toDartString(),
    ).toNativeUtf8();
  } on Object catch (e) {
    AppLog.instance.w('[OhosJS] bridge 回调异常: $e');
    return 'null'.toNativeUtf8();
  }
}

class OhosJsRuntime implements NexJsRuntime {
  OhosJsRuntime() : _runtimeId = _nextRuntimeId++ {
    _runtimeById[_runtimeId] = this;
    _handle = _bindings.create(_bridgePointer, _runtimeId);
    if (_handle == nullptr) {
      _runtimeById.remove(_runtimeId);
      throw StateError('无法创建鸿蒙 QuickJS 运行时');
    }
  }

  static final _QuickJsBindings _bindings = _QuickJsBindings.open();
  static final Pointer<NativeFunction<_BridgeNative>> _bridgePointer =
      Pointer.fromFunction<_BridgeNative>(_dispatchBridge);

  final int _runtimeId;
  final Map<String, void Function(dynamic args)> _handlers =
      <String, void Function(dynamic args)>{};
  late Pointer<Void> _handle;
  bool _disposed = false;

  /// 处理 JS 侧 sendMessage：同步调用注册的处理器，返回值固定为 JSON null
  /// （书源桥接是「消息 + 异步回填」模型，不需要同步返回值）。
  String _handleBridge(String channel, String payload) {
    final handler = _handlers[channel];
    if (handler == null) {
      return 'null';
    }
    try {
      // 透传原始字符串：上层 _decodeBridgeMessage 自身兼容 Map / JSON String。
      handler(payload);
      return 'null';
    } on Object catch (e) {
      AppLog.instance.w('[OhosJS] sendMessage 处理异常($channel): $e');
      return 'null';
    }
  }

  @override
  NexJsEvalResult evaluate(String code) {
    if (_disposed) {
      throw StateError('QuickJS 运行时已释放');
    }
    final input = code.toNativeUtf8();
    final resultOut = calloc<Pointer<Utf8>>();
    final errorOut = calloc<Pointer<Utf8>>();
    try {
      final status =
          _bindings.evaluate(_handle, input, input.length, resultOut, errorOut);
      if (status != 0) {
        final message = errorOut.value == nullptr
            ? 'QuickJS 求值失败'
            : errorOut.value.toDartString();
        return NexJsEvalResult(message, isError: true);
      }
      return NexJsEvalResult(
        resultOut.value == nullptr ? 'null' : resultOut.value.toDartString(),
      );
    } finally {
      if (resultOut.value != nullptr) {
        _bindings.freeString(resultOut.value);
      }
      if (errorOut.value != nullptr) {
        _bindings.freeString(errorOut.value);
      }
      malloc.free(input);
      calloc
        ..free(resultOut)
        ..free(errorOut);
    }
  }

  @override
  Future<NexJsEvalResult> evaluateAsync(String code) {
    // 延后一个事件循环执行：避免在原生 sendMessage 回调栈内重入求值。
    // 运行时可能在排队期间被释放（页面退出 / 换源 / 超时清理）——此时安静
    // 返回错误结果而非抛异常：抛进 Timer 的异常会以 Uncaught zone error
    // 刷屏（真机日志曾每秒数条）。
    return Future<NexJsEvalResult>(() {
      if (_disposed) {
        return const NexJsEvalResult('QuickJS 运行时已释放', isError: true);
      }
      return evaluate(code);
    });
  }

  @override
  Future<NexJsEvalResult> handlePromise(
    NexJsEvalResult promise, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    return Future<NexJsEvalResult>.error(
      UnsupportedError('鸿蒙 QuickJS 桥不支持 handlePromise，请走轮询降级'),
    );
  }

  @override
  void onMessage(String channel, void Function(dynamic message) handler) {
    _handlers[channel] = handler;
  }

  /// 显式泵空微任务队列（一般无需调用：每次 evaluate 已自动泵动）。
  void drainJobs() {
    if (_disposed || _handle == nullptr) return;
    _bindings.drainJobs(_handle);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _runtimeById.remove(_runtimeId);
    _bindings.disposeHandle(_handle);
    _handle = nullptr;
    _handlers.clear();
  }
}

class _QuickJsBindings {
  _QuickJsBindings(this.library)
      : create = library.lookupFunction<_CreateNative, _CreateDart>(
          'nexhub_qjs_create',
        ),
        evaluate = library.lookupFunction<_EvaluateNative, _EvaluateDart>(
          'nexhub_qjs_evaluate',
        ),
        disposeHandle = library
            .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
              'nexhub_qjs_dispose',
            )
            .asFunction(),
        drainJobs = library
            .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
              'nexhub_qjs_drain_jobs',
            )
            .asFunction(),
        freeString = library
            .lookup<NativeFunction<Void Function(Pointer<Utf8>)>>(
              'nexhub_qjs_free_string',
            )
            .asFunction();

  factory _QuickJsBindings.open() {
    final override = Platform.environment['NEXHUB_QUICKJS_LIBRARY'];
    if (override != null && override.isNotEmpty) {
      return _QuickJsBindings(DynamicLibrary.open(override));
    }
    return _QuickJsBindings(DynamicLibrary.open('libnexhub_quickjs.so'));
  }

  final DynamicLibrary library;
  final _CreateDart create;
  final _EvaluateDart evaluate;
  final void Function(Pointer<Void>) disposeHandle;
  final void Function(Pointer<Void>) drainJobs;
  final void Function(Pointer<Utf8>) freeString;
}
