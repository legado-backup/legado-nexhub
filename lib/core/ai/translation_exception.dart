/// 翻译链路统一异常：message 为用户可读文案（错误归一化）。
///
/// 三个翻译模块（小说段落 / 漫画页 / 视频字幕）的 catch 处统一经
/// [TranslationException.from] 归一化——底层 DioException / Timeout 的
/// 原始报文不再直接上屏，而是按「连接 / 超时 / 限流 / 额度 / 认证 /
/// 服务端 / 拒答 / 返回格式」分类；原始细节由调用方写入 [AppLog]。
///
/// [TranslationKind] 同时驱动端点路由：[isEndpointSwitchable] 为 true
/// 的错误才值得切到备用端点；认证失败与拒答等切端点通常无益。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

/// 翻译链路异常。
class TranslationException implements Exception {
  const TranslationException(
    this.message, {
    this.kind = TranslationKind.other,
    this.retryAfter,
  });

  /// 用户可读文案。
  final String message;

  /// 错误类别（失败路由：仅 connection/timeout/rateLimit/quota/server 切换）。
  final TranslationKind kind;

  /// 服务端建议的重试等待时间（来自 `Retry-After`，仅秒数形式）。
  final Duration? retryAfter;

  /// 是否值得切换到备用端点重试。
  bool get isEndpointSwitchable => switch (kind) {
        TranslationKind.connection ||
        TranslationKind.timeout ||
        TranslationKind.rateLimit ||
        TranslationKind.quota ||
        TranslationKind.server =>
          true,
        _ => false,
      };

  @override
  String toString() => message;

  /// 把底层异常归一化为可读文案。
  factory TranslationException.from(Object e) {
    if (e is TranslationException) return e;
    if (e is DioException) return _fromDio(e);
    final s = e.toString();
    final lower = s.toLowerCase();
    if (s.contains('Connection') ||
        s.contains('SocketException') ||
        s.contains('Failed host lookup') ||
        lower.contains('connection refused') ||
        lower.contains('network is unreachable')) {
      return const TranslationException(
        '网络连接失败，请检查网络后重试',
        kind: TranslationKind.connection,
      );
    }
    if (_looksQuota(lower)) {
      return const TranslationException(
        '接口额度不足或已欠费，请检查账户余额',
        kind: TranslationKind.quota,
      );
    }
    if (_looksAuth(lower)) {
      return const TranslationException(
        '接口认证失败，请检查 API Key 与接口地址',
        kind: TranslationKind.auth,
      );
    }
    if (s.contains('429') ||
        lower.contains('rate limit') ||
        lower.contains('too many requests')) {
      return const TranslationException(
        '请求过于频繁，请稍后重试',
        kind: TranslationKind.rateLimit,
      );
    }
    if (s.contains('timeout') ||
        s.contains('TimedOut') ||
        s.contains('TimeoutException')) {
      return const TranslationException(
        '请求超时，请稍后重试',
        kind: TranslationKind.timeout,
      );
    }
    if (_looksRefusal(lower)) {
      return const TranslationException(
        '模型拒绝翻译该内容',
        kind: TranslationKind.refusal,
      );
    }
    if (_looksInvalidResponse(s, lower)) {
      return const TranslationException(
        '模型返回内容无法解析',
        kind: TranslationKind.invalidResponse,
      );
    }
    // 摘要截断：原始报文可能极长（HTML 错误页等）。
    final brief = s.length > 160 ? '${s.substring(0, 160)}…' : s;
    return TranslationException('翻译失败：$brief');
  }

  static TranslationException _fromDio(DioException e) {
    final status = e.response?.statusCode;
    final body = _bodyMessage(e.response?.data);
    final lowerBody = body.toLowerCase();
    final retryAfter =
        _parseRetryAfter(e.response?.headers.value('retry-after'));

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return const TranslationException(
          '请求超时，请稍后重试',
          kind: TranslationKind.timeout,
        );
      case DioExceptionType.connectionError:
        return const TranslationException(
          '网络连接失败，请检查网络后重试',
          kind: TranslationKind.connection,
        );
      case DioExceptionType.badCertificate:
        return const TranslationException(
          '接口证书校验失败，请检查网络环境',
          kind: TranslationKind.connection,
        );
      case DioExceptionType.cancel:
        return const TranslationException('翻译请求已取消');
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        break;
    }

    if (status != null) {
      if (status == 401 || status == 403) {
        return const TranslationException(
          '接口认证失败，请检查 API Key 与接口地址',
          kind: TranslationKind.auth,
        );
      }
      if (status == 402 || _looksQuota(lowerBody)) {
        return TranslationException(
          '接口额度不足或已欠费，请检查账户余额',
          kind: TranslationKind.quota,
          retryAfter: retryAfter,
        );
      }
      if (status == 429 || status == 425) {
        return TranslationException(
          '请求过于频繁，请稍后重试',
          kind: TranslationKind.rateLimit,
          retryAfter: retryAfter,
        );
      }
      if (status == 408) {
        return const TranslationException(
          '请求超时，请稍后重试',
          kind: TranslationKind.timeout,
        );
      }
      // 5xx 优先按服务端错误处理：错误页里出现 authentication 等字样
      // 不应把可切换的故障误判为不可切换的认证失败。
      if (status >= 500) {
        return const TranslationException(
          '接口服务端错误，请稍后重试',
          kind: TranslationKind.server,
        );
      }
      if (_looksAuth(lowerBody)) {
        return const TranslationException(
          '接口认证失败，请检查 API Key 与接口地址',
          kind: TranslationKind.auth,
        );
      }
      if (_looksRefusal(lowerBody)) {
        return const TranslationException(
          '模型拒绝翻译该内容',
          kind: TranslationKind.refusal,
        );
      }
      final detail = body.isEmpty ? '' : '：$body';
      return TranslationException(
        '接口返回错误（HTTP $status）$detail',
        kind: TranslationKind.other,
      );
    }

    if (_looksQuota(lowerBody)) {
      return TranslationException(
        '接口额度不足或已欠费，请检查账户余额',
        kind: TranslationKind.quota,
        retryAfter: retryAfter,
      );
    }
    if (_looksRefusal(lowerBody)) {
      return const TranslationException(
        '模型拒绝翻译该内容',
        kind: TranslationKind.refusal,
      );
    }
    final raw = e.error?.toString() ?? e.toString();
    final lower = raw.toLowerCase();
    if (raw.contains('Connection') ||
        raw.contains('SocketException') ||
        raw.contains('Failed host lookup') ||
        lower.contains('connection refused')) {
      return const TranslationException(
        '网络连接失败，请检查网络后重试',
        kind: TranslationKind.connection,
      );
    }
    if (raw.contains('timeout') ||
        raw.contains('TimedOut') ||
        raw.contains('TimeoutException')) {
      return const TranslationException(
        '请求超时，请稍后重试',
        kind: TranslationKind.timeout,
      );
    }
    final brief = body.isNotEmpty
        ? body
        : (raw.length > 160 ? '${raw.substring(0, 160)}…' : raw);
    return TranslationException('翻译失败：$brief');
  }

  static String _bodyMessage(dynamic data) {
    if (data == null) return '';
    if (data is Map) {
      final error = data['error'];
      if (error is Map) {
        final msg = error['message'] ?? error['code'] ?? error['type'];
        if (msg != null) return _truncate(msg.toString());
      }
      final msg = data['message'];
      if (msg != null) return _truncate(msg.toString());
      try {
        return _truncate(jsonEncode(data));
      } on Object {
        return _truncate(data.toString());
      }
    }
    if (data is String) return _truncate(data);
    return _truncate(data.toString());
  }

  static String _truncate(String s) {
    final t = s.trim();
    return t.length > 160 ? '${t.substring(0, 160)}…' : t;
  }

  static Duration? _parseRetryAfter(String? raw) {
    final s = raw?.trim();
    if (s == null || s.isEmpty) return null;
    final seconds = int.tryParse(s);
    if (seconds == null || seconds <= 0) return null;
    return Duration(seconds: seconds.clamp(1, 3600));
  }

  static bool _looksQuota(String lower) =>
      lower.contains('insufficient_quota') ||
      lower.contains('quota') ||
      lower.contains('billing') ||
      lower.contains('余额') ||
      lower.contains('欠费');

  static bool _looksAuth(String lower) =>
      lower.contains('invalid api key') ||
      lower.contains('incorrect api key') ||
      lower.contains('unauthorized') ||
      lower.contains('authentication') ||
      lower.contains('invalid_api_key');

  static bool _looksRefusal(String lower) =>
      lower.contains('content_policy') ||
      lower.contains('content policy') ||
      lower.contains('content_filter') ||
      lower.contains('safety') ||
      lower.contains('refus');

  static bool _looksInvalidResponse(String raw, String lower) =>
      raw.contains('返回内容为空') ||
      raw.contains('返回格式异常') ||
      raw.contains('格式应为') ||
      lower.contains('invalid json') ||
      lower.contains('parse error') ||
      lower.contains('empty response');
}

/// 错误类别。
enum TranslationKind {
  connection,
  timeout,
  rateLimit,
  quota,
  auth,
  server,
  refusal,
  invalidResponse,
  other,
}
