/// 译文忠实度校验（漫画 / 字幕 / 小说短句共用）。
///
/// 视觉模型或文本模型可能返回「空译文 / 原文照抄 / 目标语言不对 / 拒答 /
/// 明显截断」的结果；本类把这些情况归一为可重试的问题，供翻译管线决定
/// 纠错重试、两阶段兜底或部分接受。
///
/// 判定刻意保守（宁可不报，避免把正常意译判成失败）：
/// - 拒答只在命中「无法翻译图片/请求」等元话语时成立；
/// - 原文回显只比较规范化后的完全相等（短文本豁免）；
/// - 目标语言脚本只拦截明显的整句错语言；
/// - 覆盖率按源文本字符数设下限（CJK 25%，其他 20%）。
library;

import 'translation_language.dart';
import 'vision_translation_client.dart';

/// 单条译文的问题类型。
enum TranslationFaithfulnessIssue {
  /// 译文为空。
  empty,

  /// 模型拒答（道歉 / 无法翻译 / 安全策略）。
  refusal,

  /// 译文与原文完全相同（未翻译）。
  sourceEcho,

  /// 译文明显不是目标语言脚本。
  wrongTargetScript,

  /// 译文相对原文短得异常（疑似截断/漏译）。
  lowCoverage,
}

/// 整页校验结果。
class PageFaithfulness {
  const PageFaithfulness({
    required this.accepted,
    required this.issues,
    required this.total,
  });

  /// 通过校验的区域（保持原顺序）。
  final List<VisionTextSegment> accepted;

  /// 未通过校验的区域：原索引 → 问题集合。
  final Map<int, Set<TranslationFaithfulnessIssue>> issues;

  /// 总区域数。
  final int total;

  int get issueCount => issues.length;

  double get issueRatio => total == 0 ? 0 : issueCount / total;

  bool get isClean => issues.isEmpty;

  bool get hasAccepted => accepted.isNotEmpty;

  /// 未通过比例达到 25% 且至少 2 条，或没有任何可用译文时，值得走
  /// 两阶段 OCR + 文本翻译；单条瑕疵则直接部分接受，避免多烧请求。
  bool get needsTwoPhase =>
      total > 0 &&
      (accepted.isEmpty || (issueCount >= 2 && issueRatio >= 0.25));

  List<int> get issueIndexes => issues.keys.toList()..sort();
}

/// 忠实度校验器。
abstract final class TranslationFaithfulness {
  static final RegExp _han = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff]');
  static final RegExp _kana = RegExp(r'[\u3040-\u30ff]');
  static final RegExp _hangul = RegExp(r'[\u1100-\u11ff\uac00-\ud7af]');
  static final RegExp _latin = RegExp(r'[A-Za-z]');
  static final RegExp _cyrillic = RegExp(r'[\u0400-\u04ff]');
  static final RegExp _arabic = RegExp(r'[\u0600-\u06ff]');
  static final RegExp _thai = RegExp(r'[\u0e00-\u0e7f]');

  static final RegExp _latinWord = RegExp(r"[A-Za-z][A-Za-z'’-]*");
  static final RegExp _englishStopword = RegExp(
    r"\b(the|a|an|and|or|of|to|in|is|are|was|were|be|been|it|this|that|with|"
    r"for|on|as|at|by|from|you|your|we|our|they|their|he|she|his|her|i|my|"
    r"not|but|have|has|had|will|would|can|could|should|do|does|did|what|"
    r"which|who|how|why|when|where)\b",
    caseSensitive: false,
  );
  static final RegExp _compareNoise =
      RegExp(r'''[\s\.,!?;:，。！？；：、…—–\-_"'“”‘’()（）\[\]【】《》]+''');

  /// 拒答元话语（要求同时出现「无法/不能」与「翻译/图片/请求」等词）。
  static final List<RegExp> _refusalPatterns = <RegExp>[
    RegExp(r'(作为|我是|本模型|我是一名?)\s*(AI|人工智能|语言模型|助手)'
        r'.{0,12}(无法|不能|不便|拒绝)'),
    RegExp(r'(无法|不能|不便).{0,8}(翻译|识别|处理|提供|完成)'
        r'.{0,8}(图片|图像|这张|该|你的|请求|内容|文字)'),
    RegExp(r'(我|本模型).{0,4}(无法|不能).{0,6}(访问|查看|读取)'
        r'.{0,4}(图片|图像)'),
    RegExp(r"\b(as an ai|i am an ai|i'm an ai|as a language model)\b",
        caseSensitive: false),
    RegExp(
        r"\b(i|we)\s+(can(?:'|’)?t|cannot|can not|am unable|are unable)\s+"
        r'(to\s+)?(translate|assist|help|comply|process|provide)\b',
        caseSensitive: false),
    RegExp(r'\b(unable|not able) to (translate|comply|assist|process)\b',
        caseSensitive: false),
    RegExp(r'\b(sorry,? but)\s+i\b', caseSensitive: false),
  ];

  /// 校验整页区域。
  static PageFaithfulness validatePage(
    List<VisionTextSegment> segments,
    String targetLang,
  ) {
    final accepted = <VisionTextSegment>[];
    final issues = <int, Set<TranslationFaithfulnessIssue>>{};
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final found = issuesFor(
        source: segment.text,
        translation: segment.translation,
        targetLang: targetLang,
      );
      if (found.isEmpty) {
        accepted.add(segment);
      } else {
        issues[i] = found;
      }
    }
    return PageFaithfulness(
      accepted: accepted,
      issues: issues,
      total: segments.length,
    );
  }

  /// 单条译文的问题集合；空集合表示通过。
  static Set<TranslationFaithfulnessIssue> issuesFor({
    required String source,
    required String translation,
    required String targetLang,
  }) {
    final text = translation.trim();
    if (text.isEmpty) {
      return <TranslationFaithfulnessIssue>{
        TranslationFaithfulnessIssue.empty,
      };
    }
    final result = <TranslationFaithfulnessIssue>{};
    if (looksLikeRefusal(text)) {
      result.add(TranslationFaithfulnessIssue.refusal);
    }
    if (isSourceEcho(source, text)) {
      result.add(TranslationFaithfulnessIssue.sourceEcho);
    }
    if (wrongTargetScript(text, targetLang)) {
      result.add(TranslationFaithfulnessIssue.wrongTargetScript);
    }
    if (lowCoverage(source, text)) {
      result.add(TranslationFaithfulnessIssue.lowCoverage);
    }
    return result;
  }

  /// 是否像模型拒答。长度封顶，避免把长对话里的「抱歉」误判。
  static bool looksLikeRefusal(String text) {
    final s = text.trim();
    if (s.isEmpty || s.length > 200) return false;
    for (final pattern in _refusalPatterns) {
      if (pattern.hasMatch(s)) return true;
    }
    return false;
  }

  /// 译文是否是原文的原样回显（忽略空白/标点/大小写）。
  ///
  /// 3 个字符以下的文本豁免（`OK`、`BGM`、拟声词等本来就可能不译）。
  static bool isSourceEcho(
    String source,
    String translation, {
    int minLength = 3,
  }) {
    final src = _normalize(source);
    final dst = _normalize(translation);
    if (src.length <= minLength || dst.isEmpty) return false;
    return src == dst;
  }

  /// 译文是否明显不是目标语言（只拦截整句错语言，避免误伤专名）。
  static bool wrongTargetScript(String translation, String targetLang) {
    final t = translation.trim();
    if (t.isEmpty) return false;
    final code = TranslationLanguage.bingCode(targetLang) ??
        targetLang.trim().toLowerCase();
    final han = _han.hasMatch(t);
    final kana = _kana.hasMatch(t);
    final hangul = _hangul.hasMatch(t);
    final latin = _latin.hasMatch(t);
    final latinWords = _count(_latinWord, t);
    switch (code) {
      case 'zh-Hans':
      case 'zh-Hant':
        // 中文译文里出现日文假名/韩文，且中文不占主导。
        if (!han && (kana || hangul)) return true;
        if (_count(_kana, t) >= 2 && _count(_kana, t) > _count(_han, t)) {
          return true;
        }
        // 整句英文（含常见虚词）而没有任何中文。
        if (!han && latinWords >= 3 && _englishStopword.hasMatch(t)) {
          return true;
        }
        return false;
      case 'ja':
        return !kana && (han || hangul);
      case 'ko':
        return !hangul && (han || kana);
      case 'en':
        return !latin && (han || kana || hangul);
      case 'ru':
        return !_cyrillic.hasMatch(t) && latinWords >= 3;
      case 'ar':
        return !_arabic.hasMatch(t) && latinWords >= 3;
      case 'th':
        return !_thai.hasMatch(t) && latinWords >= 3;
      default:
        return false;
    }
  }

  /// 译文相对原文是否短得异常（疑似截断/漏译）。
  static bool lowCoverage(String source, String translation) {
    final src = _visibleLength(source);
    if (src < 12) return false;
    final dst = _visibleLength(translation);
    final cjkSource =
        _han.hasMatch(source) || _kana.hasMatch(source) || _hangul.hasMatch(source);
    final floor = cjkSource ? 0.25 : 0.20;
    return dst < src * floor;
  }

  static String _normalize(String text) =>
      text.toLowerCase().replaceAll(_compareNoise, '');

  static int _visibleLength(String text) =>
      text.replaceAll(_compareNoise, '').runes.length;

  static int _count(RegExp pattern, String text) =>
      pattern.allMatches(text).length;
}
