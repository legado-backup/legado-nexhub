// NexHub 鸿蒙 QuickJS 桥：C API。
//
// 基于 abner/quickjs-c-bridge（MIT）的调用形态改写，与 flutter_js 0.8.x 在
// Android 上使用的 C 桥同源；相对于参考实现增加了「每次 evaluate 后泵空微任务
// 队列」——书源 JS 上下文（ctx.http.get 等）依赖 Promise 链在桥接回调后继续
// 执行，微任务不泵则 .then() 永不触发。
//
// 导出给 Dart（dart:ffi）的符号：
//   nexhub_qjs_create(bridge, runtime_id) -> handle
//   nexhub_qjs_evaluate(handle, code, len, &result, &error) -> int32
//   nexhub_qjs_drain_jobs(handle) -> void
//   nexhub_qjs_dispose(handle) -> void
//   nexhub_qjs_free_string(str) -> void
// JS 全局注入 sendMessage(channel, message)：同步调用 Dart 回调并返回其 JSON。

#include "quickjs/quickjs.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>

#ifdef _MSC_VER
#define NEXHUB_QJS_EXPORT __declspec(dllexport)
#else
#define NEXHUB_QJS_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

using NexhubQjsBridgeCallback =
    char *(*)(intptr_t runtime_id, const char *channel, const char *message);

struct NexhubQjsHandle {
  JSRuntime *runtime;
  JSContext *context;
  NexhubQjsBridgeCallback bridge;
  intptr_t runtime_id;
};

static char *nexhub_qjs_copy_string(const char *value) {
  if (value == nullptr) {
    return nullptr;
  }
  const size_t length = std::strlen(value);
  auto *copy = static_cast<char *>(std::malloc(length + 1));
  if (copy == nullptr) {
    return nullptr;
  }
  std::memcpy(copy, value, length + 1);
  return copy;
}

// 泵空 QuickJS 微任务队列（Promise .then/.catch 的继续执行在此发生）。
// 上限保护避免恶意脚本制造无限微任务导致挂死。
static void nexhub_qjs_drain_jobs_impl(JSRuntime *runtime) {
  JSContext *ctx = nullptr;
  int guard = 0;
  while (JS_ExecutePendingJob(runtime, &ctx) > 0) {
    if (++guard > 100000) {
      break;
    }
  }
}

static JSValue nexhub_qjs_send_message(JSContext *context,
                                       JSValueConst,
                                       int argc,
                                       JSValueConst *argv) {
  auto *handle = static_cast<NexhubQjsHandle *>(JS_GetContextOpaque(context));
  if (handle == nullptr || handle->bridge == nullptr || argc < 2) {
    return JS_NULL;
  }

  const char *channel = JS_ToCString(context, argv[0]);
  const char *message = JS_ToCString(context, argv[1]);
  if (channel == nullptr || message == nullptr) {
    if (channel != nullptr) {
      JS_FreeCString(context, channel);
    }
    if (message != nullptr) {
      JS_FreeCString(context, message);
    }
    return JS_NULL;
  }

  char *encoded_result = handle->bridge(handle->runtime_id, channel, message);
  JS_FreeCString(context, channel);
  JS_FreeCString(context, message);
  if (encoded_result == nullptr) {
    return JS_NULL;
  }

  JSValue result = JS_ParseJSON(
      context,
      encoded_result,
      std::strlen(encoded_result),
      "<dart-bridge>");
  std::free(encoded_result);
  if (JS_IsException(result)) {
    JS_FreeValue(context, result);
    return JS_NULL;
  }
  return result;
}

extern "C" {

NEXHUB_QJS_EXPORT NexhubQjsHandle *nexhub_qjs_create(
    NexhubQjsBridgeCallback bridge,
    intptr_t runtime_id) {
  auto *handle = new (std::nothrow) NexhubQjsHandle{
      JS_NewRuntime(),
      nullptr,
      bridge,
      runtime_id,
  };
  if (handle == nullptr || handle->runtime == nullptr) {
    delete handle;
    return nullptr;
  }

  JS_SetMemoryLimit(handle->runtime, 64 * 1024 * 1024);
  JS_SetMaxStackSize(handle->runtime, 1024 * 1024);
  handle->context = JS_NewContext(handle->runtime);
  if (handle->context == nullptr) {
    JS_FreeRuntime(handle->runtime);
    delete handle;
    return nullptr;
  }

  JS_SetContextOpaque(handle->context, handle);
  JSValue global = JS_GetGlobalObject(handle->context);
  JS_SetPropertyStr(
      handle->context,
      global,
      "sendMessage",
      JS_NewCFunction(
          handle->context,
          nexhub_qjs_send_message,
          "sendMessage",
          2));
  JS_FreeValue(handle->context, global);
  return handle;
}

NEXHUB_QJS_EXPORT int32_t nexhub_qjs_evaluate(NexhubQjsHandle *handle,
                                              const char *code,
                                              intptr_t code_length,
                                              char **result,
                                              char **error) {
  if (result != nullptr) {
    *result = nullptr;
  }
  if (error != nullptr) {
    *error = nullptr;
  }
  if (handle == nullptr || handle->context == nullptr || code == nullptr) {
    if (error != nullptr) {
      *error = nexhub_qjs_copy_string("Invalid QuickJS runtime or source");
    }
    return 1;
  }

  JS_UpdateStackTop(handle->runtime);
  JSValue value = JS_Eval(
      handle->context,
      code,
      static_cast<size_t>(code_length),
      "<nexhub-script>",
      JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(value)) {
    JS_FreeValue(handle->context, value);
    JSValue exception = JS_GetException(handle->context);
    const char *message = JS_ToCString(handle->context, exception);
    if (error != nullptr) {
      *error = nexhub_qjs_copy_string(
          message == nullptr ? "QuickJS evaluation failed" : message);
    }
    if (message != nullptr) {
      JS_FreeCString(handle->context, message);
    }
    JS_FreeValue(handle->context, exception);
    nexhub_qjs_drain_jobs_impl(handle->runtime);
    return 1;
  }

  const char *string_value = JS_ToCString(handle->context, value);
  if (result != nullptr) {
    *result = nexhub_qjs_copy_string(
        string_value == nullptr ? "null" : string_value);
  }
  if (string_value != nullptr) {
    JS_FreeCString(handle->context, string_value);
  }
  JS_FreeValue(handle->context, value);
  nexhub_qjs_drain_jobs_impl(handle->runtime);
  return 0;
}

NEXHUB_QJS_EXPORT void nexhub_qjs_drain_jobs(NexhubQjsHandle *handle) {
  if (handle == nullptr || handle->runtime == nullptr) {
    return;
  }
  nexhub_qjs_drain_jobs_impl(handle->runtime);
}

NEXHUB_QJS_EXPORT void nexhub_qjs_dispose(NexhubQjsHandle *handle) {
  if (handle == nullptr) {
    return;
  }
  if (handle->context != nullptr) {
    JS_SetContextOpaque(handle->context, nullptr);
    JS_FreeContext(handle->context);
  }
  if (handle->runtime != nullptr) {
    JS_FreeRuntime(handle->runtime);
  }
  delete handle;
}

NEXHUB_QJS_EXPORT void nexhub_qjs_free_string(char *value) {
  std::free(value);
}

}
