/// Bing Edge 免费翻译客户端。
///
/// 非公开端点、无 SLA：批量上限保守取值，网络/超时/429/5xx 重试，
/// 连续失败触发 5 分钟熔断。所有异常归一化为 [TranslationException]。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../utils/app_log.dart';
import 'translation_exception.dart';
import 'translation_language.dart';

class BingTranslationClient {
  BingTranslationClient({
    Dio? dio,
    Future<void> Function(Duration)? delay,
  })  : _dio = dio ?? Dio(),
        _delay = delay ?? Future<void>.delayed;

  final Dio _dio;
  final Future<void> Function(Duration) _delay;

  static const String endpoint =
      'https://edge.microsoft.com/translate/translatetext';
  static const int maxBatchItems = 80;
  static const int maxBatchChars = 12000;
  static const int maxItemChars = 8000;

  static const int _maxRetries = 2;
  static const int _failuresToTrip = 3;
  static const Duration _cooldown = Duration(minutes: 5);

  static int _consecutiveFailures = 0;
  static DateTime? _openUntil;

  /// 测试时钟注入点。
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// 清空熔断状态（测试用）。
  @visibleForTesting
  static void resetCircuitBreaker() {
    _consecutiveFailures = 0;
    _openUntil = null;
    clock = DateTime.now;
  }

  /// 当前是否处于熔断冷却期；冷却结束自动复位。
  static bool get circuitOpen {
    final until = _openUntil;
    if (until == null) return false;
    if (clock().isBefore(until)) return true;
    _openUntil = null;
    _consecutiveFailures = 0;
    return false;
  }

  /// 翻译文本列表；返回与输入等长（空串原样返回）。
  Future<List<String>> translate({
    required List<String> texts,
    required String targetLang,
    String? fromLang,
  }) async {
    if (texts.isEmpty) return const <String>[];
    final target = TranslationLanguage.bingCode(targetLang);
    if (target == null) {
      throw const TranslationException('目标语言暂不支持 Bing 免费翻译');
    }
    if (circuitOpen) {
      throw const TranslationException('Bing 免费翻译暂时不可用，请稍后重试');
    }

    final result = List<String>.filled(texts.length, '');
    final unique = <String, List<int>>{};
    for (var i = 0; i < texts.length; i++) {
      final text = texts[i];
      if (text.trim().isEmpty) continue;
      unique.putIfAbsent(text, () => <int>[]).add(i);
    }
    if (unique.isEmpty) return result;

    final uniqueTexts = unique.keys.toList(growable: false);
    final pieces = <_Piece>[];
    for (var owner = 0; owner < uniqueTexts.length; owner++) {
      for (final part in _splitLongText(uniqueTexts[owner])) {
        pieces.add(_Piece(owner, part));
      }
    }
    final ownerParts = <List<String>>[
      for (var i = 0; i < uniqueTexts.length; i++) <String>[],
    ];
    try {
      for (final batch in _buildBatches(pieces)) {
        final translations = await _postBatch(
          <String>[for (final p in batch) p.text],
          target,
          fromLang,
        );
        for (var i = 0; i < batch.length; i++) {
          ownerParts[batch[i].owner].add(translations[i]);
        }
      }
    } on TranslationException {
      _recordFailure();
      rethrow;
    } on DioException catch (e) {
      _recordFailure();
      AppLog.instance.w('[Bing翻译] 请求失败: $e');
      final code = e.response?.statusCode;
      throw TranslationException(
        code == 429 ? '请求过于频繁，请稍后重试' : 'Bing 免费翻译暂时不可用，请稍后重试',
        kind: code == 429 ? TranslationKind.rateLimit : TranslationKind.other,
      );
    } on Object catch (e) {
      _recordFailure();
      AppLog.instance.w('[Bing翻译] 请求失败: $e');
      throw const TranslationException('Bing 免费翻译暂时不可用，请稍后重试');
    }

    _consecutiveFailures = 0;
    _openUntil = null;
    for (var owner = 0; owner < uniqueTexts.length; owner++) {
      final joined = ownerParts[owner].join();
      if (joined.trim().isEmpty) {
        throw const TranslationException('Bing 返回内容为空');
      }
      for (final index in unique[uniqueTexts[owner]]!) {
        result[index] = joined;
      }
    }
    return result;
  }

  Iterable<List<_Piece>> _buildBatches(List<_Piece> pieces) sync* {
    var batch = <_Piece>[];
    var chars = 0;
    for (final piece in pieces) {
      if (batch.isNotEmpty &&
          (batch.length >= maxBatchItems ||
              chars + piece.text.length > maxBatchChars)) {
        yield batch;
        batch = <_Piece>[];
        chars = 0;
      }
      batch.add(piece);
      chars += piece.text.length;
    }
    if (batch.isNotEmpty) yield batch;
  }

  List<String> _splitLongText(String text) {
    if (text.length <= maxItemChars) return <String>[text];
    final out = <String>[];
    var start = 0;
    while (text.length - start > maxItemChars) {
      final limit = start + maxItemChars;
      var cut = limit;
      final floor = (limit - 1000).clamp(start + 1, limit);
      for (var i = limit; i > floor; i--) {
        final c = text[i - 1];
        if (c == '\n' ||
            c == '。' ||
            c == '！' ||
            c == '？' ||
            c == '.' ||
            c == '!' ||
            c == '?' ||
            c == '；' ||
            c == ';') {
          cut = i;
          break;
        }
      }
      out.add(text.substring(start, cut));
      start = cut;
    }
    if (start < text.length) out.add(text.substring(start));
    return out;
  }

  Future<List<String>> _postBatch(
    List<String> texts,
    String target,
    String? fromLang,
  ) async {
    var attempt = 0;
    while (true) {
      try {
        final resp = await _dio.post<dynamic>(
          endpoint,
          queryParameters: <String, dynamic>{
            'to': target,
            'isEnterpriseClient': 'false',
            if (fromLang != null && fromLang.isNotEmpty) 'from': fromLang,
          },
          options: Options(
            contentType: Headers.jsonContentType,
            sendTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
          ),
          data: texts,
        );
        return _parse(resp.data, texts, target);
      } on DioException catch (e) {
        if (!_retryable(e) || attempt >= _maxRetries) rethrow;
        await _delay(Duration(milliseconds: attempt == 0 ? 500 : 1500));
        attempt++;
      }
    }
  }

  List<String> _parse(dynamic data, List<String> sources, String target) {
    dynamic decoded = data;
    if (decoded is String) {
      try {
        decoded = jsonDecode(decoded);
      } on Object {
        throw const TranslationException('Bing 返回格式异常');
      }
    }
    if (decoded is! List || decoded.length != sources.length) {
      throw const TranslationException('Bing 返回格式异常');
    }
    final out = <String>[];
    for (var i = 0; i < decoded.length; i++) {
      final item = decoded[i];
      if (item is! Map) {
        throw const TranslationException('Bing 返回格式异常');
      }
      final translations = item['translations'];
      final text = translations is List &&
              translations.isNotEmpty &&
              translations.first is Map
          ? (translations.first as Map)['text'] as String?
          : null;
      if (text == null || text.trim().isEmpty) {
        throw const TranslationException('Bing 返回内容为空');
      }
      final detected = item['detectedLanguage'] is Map
          ? ((item['detectedLanguage'] as Map)['language'] as String?)
          : null;
      out.add(_sameDetected(detected, target) ? sources[i] : text);
    }
    return out;
  }

  static bool _sameDetected(String? detected, String target) {
    if (detected == null) return false;
    final d = detected.toLowerCase();
    final t = target.toLowerCase();
    if (d == t) return true;
    if (t.startsWith('zh') || d.startsWith('zh')) return false;
    return d.split('-').first == t.split('-').first;
  }

  static bool _retryable(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        return true;
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        return code == 429 || code >= 500;
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
        return false;
      default:
        return false;
    }
  }

  static void _recordFailure() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= _failuresToTrip) {
      _openUntil = clock().add(_cooldown);
      AppLog.instance.w('[Bing翻译] 连续失败 $_consecutiveFailures 次，熔断 5 分钟');
    }
  }
}

class _Piece {
  const _Piece(this.owner, this.text);

  final int owner;
  final String text;
}
