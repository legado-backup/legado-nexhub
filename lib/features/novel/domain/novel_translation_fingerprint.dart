/// 小说译文缓存指纹：判断缓存译文是否仍对应当前原文、术语与风格。
///
/// 只纳入真正影响译文的输入：原文、目标语言、原文中实际命中的术语
/// （术语表按出现过滤，未出现的术语增删不误报过期）、风格与 CoT。
/// 指纹不匹配时由阅读器提示重译，不自动删除缓存。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/ai/glossary_manager.dart';
import '../../../core/ai/glossary_matcher.dart';
import '../../../core/ai/prompt_builder.dart';
import '../../../core/ai/translation_options_store.dart';

abstract final class NovelTranslationFingerprint {
  /// 输入组成变更时递增，使旧指纹整体失效。
  static const int version = 1;

  static String compute({
    required List<String> sources,
    required String lang,
    List<GlossaryEntry> glossary = const <GlossaryEntry>[],
    TranslationStyle style = TranslationStyle.standard,
    bool cot = false,
  }) {
    final applicable = GlossaryMatcher.entriesInTexts(glossary, sources);
    final glossaryPart = <String>[
      for (final entry in applicable)
        jsonEncode(<String>[
          entry.term,
          entry.preferred,
          ...entry.aliases.take(3),
        ]),
    ]..sort();
    final payload = jsonEncode(<String, dynamic>{
      'v': version,
      'lang': lang,
      'style': style.storageValue,
      'cot': cot,
      'sources': <String>[
        for (final source in sources) _normalizeSource(source),
      ],
      'glossary': glossaryPart,
    });
    return sha256.convert(utf8.encode(payload)).toString();
  }

  static String _normalizeSource(String text) =>
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  /// 按当前术语表/风格/CoT 计算作品本章指纹；读取失败返回 null。
  static Future<String?> computeForWork({
    required String? workId,
    required String lang,
    required List<String> sources,
    GlossaryManager? glossaryManager,
    TranslationOptionsStore? options,
  }) async {
    try {
      final store = options ?? TranslationOptionsStore();
      final glossary =
          await (glossaryManager ?? GlossaryManager()).effectiveEntries(workId, lang);
      final style = await store.effectiveStyle(workId);
      final cot = await store.getCotEnabled();
      return compute(
        sources: sources,
        lang: lang,
        glossary: glossary,
        style: style,
        cot: cot,
      );
    } on Object {
      return null;
    }
  }

  /// 缓存指纹为空（旧缓存）或当前输入读取失败时，不提示过期。
  static Future<bool> isStale({
    required String? cachedFingerprint,
    required String? workId,
    required String lang,
    required List<String> sources,
    GlossaryManager? glossaryManager,
    TranslationOptionsStore? options,
  }) async {
    final cached = cachedFingerprint?.trim() ?? '';
    if (cached.isEmpty) return false;
    final current = await computeForWork(
      workId: workId,
      lang: lang,
      sources: sources,
      glossaryManager: glossaryManager,
      options: options,
    );
    return current != null && current.isNotEmpty && current != cached;
  }
}
