/// 模型 JSON 输出的容错解析。
///
/// 部分模型会带 markdown 围栏或前后说明文字，直接 `jsonDecode` 会失败；
/// [tryDecode] 先尝试原文，再按括号配对截取最外层数组/对象（跳过字符串
/// 内的括号与转义），全部失败返回 null，由调用方决定降级。
library;

import 'dart:convert';

abstract final class LlmJson {
  /// 解析任意 JSON 值；失败返回 null。
  static dynamic tryDecode(String raw) {
    final text = stripFence(raw.trim());
    if (text.isEmpty) return null;
    for (final candidate in _candidates(text)) {
      try {
        return jsonDecode(candidate);
      } on FormatException {
        continue;
      }
    }
    return null;
  }

  /// 解析 JSON 对象；结果不是对象时返回 null。
  static Map<String, dynamic>? tryDecodeObject(String raw) {
    final decoded = tryDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  /// 解析 JSON 数组；结果不是数组时返回 null。
  static List<dynamic>? tryDecodeArray(String raw) {
    final decoded = tryDecode(raw);
    return decoded is List ? decoded : null;
  }

  /// 剥除 markdown 代码围栏（```json ... ``` / ``` ... ```）。
  static String stripFence(String raw) {
    final match = RegExp(
      r'```(?:json|JSON)?\s*([\s\S]*?)```',
      caseSensitive: false,
    ).firstMatch(raw);
    return match == null ? raw : match.group(1)!.trim();
  }

  static Iterable<String> _candidates(String text) sync* {
    yield text;
    final array = _sliceBalanced(text, '[', ']');
    if (array != null) yield array;
    final object = _sliceBalanced(text, '{', '}');
    if (object != null) yield object;
  }

  /// 从 [text] 中截取第一个括号配对完整的片段。
  static String? _sliceBalanced(String text, String open, String close) {
    var searchFrom = 0;
    while (true) {
      final start = text.indexOf(open, searchFrom);
      if (start < 0) return null;
      var depth = 0;
      var inString = false;
      var escaped = false;
      for (var i = start; i < text.length; i++) {
        final ch = text[i];
        if (inString) {
          if (escaped) {
            escaped = false;
          } else if (ch == '\\') {
            escaped = true;
          } else if (ch == '"') {
            inString = false;
          }
          continue;
        }
        if (ch == '"') {
          inString = true;
        } else if (ch == open) {
          depth++;
        } else if (ch == close) {
          depth--;
          if (depth == 0) return text.substring(start, i + 1);
        }
      }
      searchFrom = start + 1;
    }
  }
}
