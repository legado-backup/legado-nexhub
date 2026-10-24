/// 逐条 ID 翻译协议（两阶段漫画翻译 / 短句批量翻译共用）。
///
/// 编码格式：每行 `编号|原文`。解析坚持「编号对位」而不按出现顺序猜位，
/// 避免模型漏条时整段译文错位；同时容忍常见的模型输出噪声：
/// - 行首编号可带 `[]` / `()` / `【】` 包裹、markdown 加粗、项目符号；
/// - 分隔符支持 `|` `:` `：` `>` `→` `;` `—` `–` `-` `、`、右括号或空白；
/// - 小数/版本号（如 `1.5`）不会被误判为编号。
///
/// 重号、越界号、空译文都计入问题，由调用方决定定向重试或部分接受。
library;

/// 一次 ID 协议解析结果。
class IdTranslationParse {
  const IdTranslationParse({
    required this.translations,
    required this.missingIds,
    required this.duplicateIds,
    required this.unknownIds,
    required this.lineCount,
  });

  /// 通过校验的编号 → 译文（按编号索引）。
  final Map<int, String> translations;

  /// 期望出现但未解析到有效译文的编号（升序）。
  final List<int> missingIds;

  /// 重复出现的编号（保留首次出现的译文）。
  final List<int> duplicateIds;

  /// 不在期望集合内的编号。
  final List<int> unknownIds;

  /// 成功解析出的行数（含越界/重复行，用于诊断）。
  final int lineCount;

  bool get hasStructureIssues =>
      duplicateIds.isNotEmpty || unknownIds.isNotEmpty;

  bool get isComplete => missingIds.isEmpty && !hasStructureIssues;

  bool get hasAny => translations.isNotEmpty;
}

/// `编号|原文` 编解码器。
abstract final class IdTranslationProtocol {
  static const int _maxId = 99999;

  /// 编号后的分隔符（右括号/句点单独处理）。
  static const String _separators = '|:：>→;；—–-、';

  /// 把有序文本编码为从 1 开始的 `编号|原文` 行；空文本跳过。
  static String encode(List<String> texts) {
    final entries = <int, String>{};
    for (var i = 0; i < texts.length; i++) {
      entries[i + 1] = texts[i];
    }
    return encodeMap(entries);
  }

  /// 把「编号 → 原文」编码为 `编号|原文` 行；空文本跳过。
  static String encodeMap(Map<int, String> texts) {
    final ids = texts.keys.toList()..sort();
    final buf = StringBuffer();
    for (final id in ids) {
      final text = _flatten(texts[id] ?? '');
      if (text.isEmpty) continue;
      if (buf.isNotEmpty) buf.writeln();
      buf.write('$id|$text');
    }
    return buf.toString();
  }

  /// 解析模型输出，与 [expectedIds] 对位。
  static IdTranslationParse parse(
    String raw, {
    required Iterable<int> expectedIds,
  }) {
    final expected = expectedIds.toSet();
    final translations = <int, String>{};
    final duplicates = <int>[];
    final unknown = <int>[];
    var lineCount = 0;

    var body = raw.trim();
    // 剥 markdown 围栏（围栏可能包住整段输出）。
    body = body
        .replaceAll(RegExp(r'```[a-zA-Z]*'), '')
        .replaceAll('```', '');

    for (final line in body.split(RegExp(r'\r?\n'))) {
      final parsed = _parseLine(line);
      if (parsed == null) continue;
      lineCount++;
      final (id, text) = parsed;
      if (!expected.contains(id)) {
        unknown.add(id);
        continue;
      }
      if (translations.containsKey(id)) {
        duplicates.add(id);
        continue;
      }
      translations[id] = text;
    }

    final missing = <int>[
      for (final id in expected)
        if (!translations.containsKey(id)) id,
    ]..sort();
    duplicates.sort();
    unknown.sort();
    return IdTranslationParse(
      translations: translations,
      missingIds: missing,
      duplicateIds: duplicates,
      unknownIds: unknown,
      lineCount: lineCount,
    );
  }

  /// 解析从 1 开始连续编号的输出。
  static IdTranslationParse parseSequential(String raw, int expectedCount) =>
      parse(
        raw,
        expectedIds: <int>[
          for (var i = 1; i <= expectedCount; i++) i,
        ],
      );

  /// 把解析问题压成一行提示（用于日志/定向重试提示词）。
  static String describeIssues(IdTranslationParse parse) {
    final parts = <String>[];
    if (parse.missingIds.isNotEmpty) {
      parts.add('缺少编号 ${_compactIds(parse.missingIds)}');
    }
    if (parse.duplicateIds.isNotEmpty) {
      parts.add('重复编号 ${_compactIds(parse.duplicateIds)}');
    }
    if (parse.unknownIds.isNotEmpty) {
      parts.add('越界编号 ${_compactIds(parse.unknownIds)}');
    }
    return parts.join('；');
  }

  static String _compactIds(List<int> ids) {
    if (ids.length <= 12) return ids.join(', ');
    return '${ids.take(12).join(', ')}…';
  }

  static String _flatten(String text) =>
      text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();

  /// 解析单行；不是「编号 + 分隔 + 非空译文」时返回 null。
  static (int, String)? _parseLine(String line) {
    var s = line.trim();
    if (s.isEmpty) return null;
    // 项目符号（先剥，避免 `- **1|...**` 的加粗标记挡住编号）。
    s = s.replaceFirst(RegExp(r'^[-*•·]\s+'), '');
    // 整行 markdown 强调 / 行内代码。
    s = s
        .replaceAll(RegExp(r'^[\*_`~]+'), '')
        .replaceAll(RegExp(r'[\*_`~]+$'), '')
        .trim();

    var hasOpening = false;
    if (s.isNotEmpty &&
        (s.startsWith('[') || s.startsWith('(') || s.startsWith('【'))) {
      hasOpening = true;
      s = s.substring(1).trimLeft();
    }

    final idMatch = RegExp(r'^(\d{1,5})').firstMatch(s);
    if (idMatch == null) return null;
    final id = int.tryParse(idMatch.group(1)!);
    if (id == null || id <= 0 || id > _maxId) return null;

    var rest = s.substring(idMatch.end);
    if (hasOpening) {
      if (rest.isEmpty || !_isCloser(rest[0])) return null;
      rest = rest.substring(1);
    }

    if (rest.startsWith('.')) {
      // 句点后必须有空白，避免把 `1.5` 当成编号 1。
      rest = rest.substring(1);
      if (rest.isNotEmpty && !_startsWithWhitespace(rest)) return null;
    } else if (rest.isNotEmpty && _isCloser(rest[0])) {
      rest = rest.substring(1);
    } else if (rest.isNotEmpty && _separators.contains(rest[0])) {
      rest = rest.substring(1);
    } else if (rest.isEmpty || !_startsWithWhitespace(rest)) {
      return null;
    }

    rest = rest.trimLeft();
    if (rest.isNotEmpty && _separators.contains(rest[0])) {
      rest = rest.substring(1);
    }
    final text = rest.trim();
    return text.isEmpty ? null : (id, text);
  }

  static bool _isCloser(String ch) =>
      ch == ']' || ch == ')' || ch == '】' || ch == '）';

  static bool _startsWithWhitespace(String s) =>
      s.isNotEmpty && RegExp(r'^\s').hasMatch(s);
}
