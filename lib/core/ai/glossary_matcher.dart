/// 术语匹配（纯函数）：按语言习惯判断词条是否出现、按出现过滤注入、
/// 统计语料频次。
///
/// 注入侧只保留「本批原文确实出现」的词条，取代固定条数截断：既避免
/// 无关词条挤占提示词预算，也让长术语表在超限时优先生效于当前文本。
library;

import 'glossary_manager.dart';

abstract final class GlossaryMatcher {
  /// 只按完整词条匹配的类型：称谓、敬称、口癖、固定表达。
  /// 这些条目的别名多为裸名，按别名匹配会把语境特定的译法注入普通称呼。
  static const Set<String> sourceOnlyTypes = <String>{
    'appellation',
    'honorific',
    'speech',
    'fixed_expression',
  };

  /// 单批注入上限（条 / 字符）：防提示词膨胀挤占正文预算。
  static const int defaultMaxEntries = 80;
  static const int defaultMaxChars = 4000;

  /// NFKC 近似归一：全角 ASCII → 半角、统一小写。
  /// 片假名/汉字不在全角 ASCII 区间，保持原样（CJK 走子串匹配）。
  static String normalize(String text) {
    final buf = StringBuffer();
    for (final rune in text.runes) {
      if (rune >= 0xFF01 && rune <= 0xFF5E) {
        buf.writeCharCode(rune - 0xFEE0);
      } else if (rune == 0x3000) {
        buf.write(' ');
      } else {
        buf.writeCharCode(rune);
      }
    }
    return buf.toString().toLowerCase();
  }

  /// 词条原文是否出现在 [text] 中。
  ///
  /// 拉丁/希腊/西里尔等以空格分词的文字按词边界匹配（避免 Ann 命中
  /// Anna）；CJK 连续书写按子串匹配。
  static bool occursIn(String source, String text) {
    final key = normalize(source).trim();
    if (key.isEmpty) return false;
    return _spans(key, normalize(text)).isNotEmpty;
  }

  /// 只保留在 [texts] 中实际出现的词条（保持传入顺序，不排序）。
  static List<GlossaryEntry> entriesInTexts(
    List<GlossaryEntry> entries,
    Iterable<String> texts, {
    int maxEntries = defaultMaxEntries,
    int maxChars = defaultMaxChars,
  }) {
    if (entries.isEmpty) return const <GlossaryEntry>[];
    final haystack = <String>[
      for (final t in texts)
        if (t.trim().isNotEmpty) normalize(t),
    ];
    if (haystack.isEmpty) return const <GlossaryEntry>[];
    final result = <GlossaryEntry>[];
    var chars = 0;
    for (final entry in entries) {
      if (entry.term.trim().isEmpty || entry.preferred.trim().isEmpty) continue;
      final keys = <String>{
        for (final s in matchSources(entry))
          if (normalize(s).trim().isNotEmpty) normalize(s).trim(),
      };
      final hit = keys.any(
        (key) => haystack.any((text) => _spans(key, text).isNotEmpty),
      );
      if (!hit) continue;
      final cost = entry.term.length +
          entry.preferred.length +
          entry.aliases.fold<int>(0, (sum, a) => sum + a.length);
      if (result.length >= maxEntries || chars + cost > maxChars) break;
      result.add(entry);
      chars += cost;
    }
    return result;
  }

  /// 单段文本版本（审校/润色等按段调用）。
  static List<GlossaryEntry> entriesInText(
    List<GlossaryEntry> entries,
    String text, {
    int maxEntries = defaultMaxEntries,
    int maxChars = defaultMaxChars,
  }) =>
      entriesInTexts(entries, <String>[text],
          maxEntries: maxEntries, maxChars: maxChars);

  /// 词条在归一化语料中的出现次数：原文与别名合并，重叠位置算一次。
  static int occurrenceCount(GlossaryEntry entry, String normalizedCorpus) {
    final keys = <String>{
      for (final s in matchSources(entry))
        if (normalize(s).trim().isNotEmpty) normalize(s).trim(),
    };
    if (keys.isEmpty) return 0;
    final spans = <(int, int)>[];
    for (final key in keys) {
      spans.addAll(_spans(key, normalizedCorpus));
    }
    if (spans.isEmpty) return 0;
    spans.sort((a, b) => a.$1.compareTo(b.$1));
    var count = 0;
    var activeEnd = -1;
    for (final span in spans) {
      if (span.$1 >= activeEnd) {
        count++;
        activeEnd = span.$2;
      } else if (span.$2 > activeEnd) {
        activeEnd = span.$2;
      }
    }
    return count;
  }

  /// 语料中出现至少 [minOccurrences] 次的词条（提取上下文用）。
  static List<GlossaryEntry> recurringEntries(
    List<GlossaryEntry> entries,
    String corpus, {
    int minOccurrences = 2,
  }) {
    if (entries.isEmpty || corpus.trim().isEmpty) {
      return const <GlossaryEntry>[];
    }
    final normalized = normalize(corpus);
    return <GlossaryEntry>[
      for (final e in entries)
        if (occurrenceCount(e, normalized) >= minOccurrences) e,
    ];
  }

  /// 允许参与匹配的原文写法：语境相关类型只匹配完整词条。
  static List<String> matchSources(GlossaryEntry entry) =>
      sourceOnlyTypes.contains(entry.type)
          ? <String>[entry.term]
          : <String>[entry.term, ...entry.aliases];

  /// 返回 [key] 在 [haystack]（均已归一化）中的非重叠出现区间。
  static List<(int, int)> _spans(String key, String haystack) {
    final spans = <(int, int)>[];
    if (key.isEmpty || haystack.isEmpty) return spans;
    if (!_isLatinLike(key)) {
      var start = 0;
      while (true) {
        final idx = haystack.indexOf(key, start);
        if (idx < 0) break;
        spans.add((idx, idx + key.length));
        start = idx + key.length;
      }
      return spans;
    }
    var start = 0;
    while (true) {
      final idx = haystack.indexOf(key, start);
      if (idx < 0) break;
      final before = idx == 0 ? null : haystack.codeUnitAt(idx - 1);
      final afterIdx = idx + key.length;
      final after = afterIdx >= haystack.length
          ? null
          : haystack.codeUnitAt(afterIdx);
      if (!_isWordChar(before) && !_isWordChar(after)) {
        spans.add((idx, afterIdx));
        start = afterIdx;
      } else {
        start = idx + 1;
      }
    }
    return spans;
  }

  /// 词条是否属于以空格分词的文字（拉丁/希腊/西里尔）；含 CJK 则否。
  static bool _isLatinLike(String key) {
    for (final rune in key.runes) {
      if (_isCjk(rune)) return false;
    }
    return true;
  }

  static bool _isCjk(int rune) =>
      (rune >= 0x3040 && rune <= 0x30FF) || // 假名
      (rune >= 0x3400 && rune <= 0x9FFF) || // 汉字
      (rune >= 0xAC00 && rune <= 0xD7AF) || // 谚文
      (rune >= 0xF900 && rune <= 0xFAFF); // 兼容汉字

  /// 词边界判定字符（小写后）：ASCII 字母数字、下划线、拉丁扩展、
  /// 希腊/西里尔。CJK 视作天然边界，使「Annは」仍能命中 Ann。
  static bool _isWordChar(int? code) {
    if (code == null) return false;
    if (code == 0x5F) return true;
    if (code >= 0x30 && code <= 0x39) return true;
    if (code >= 0x61 && code <= 0x7A) return true;
    if (code >= 0xC0 && code <= 0x24F) return true;
    if (code >= 0x370 && code <= 0x3FF) return true;
    if (code >= 0x400 && code <= 0x4FF) return true;
    return false;
  }
}
