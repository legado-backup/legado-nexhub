/// 漫画滚动上下文构建器。
///
/// 从缓存读取当前页之前的已译页（最多 3 页），抽取通过忠实度校验的
/// 「原文 → 译文」对，按 32 对 / 1800 字符双重预算裁剪（保留最近内容），
/// 供下一页翻译理解指代与保持译名一致。
///
/// 只读缓存、不触发网络；上下文仅作参考，不会扩大翻译范围。
library;

import '../../../core/ai/translation_faithfulness.dart';
import '../../../core/ai/vision_translation_client.dart';
import '../../../core/comic/comic_translation_manager.dart';

/// 漫画上下文收集器。
abstract final class ComicContextBuilder {
  static const int maxPages = 3;
  static const int maxPairs = 32;
  static const int maxChars = 1800;

  /// 收集前 [maxPages] 页的可用译文对（时间升序，最近的在末尾）。
  static Future<List<TranslationContextPair>> collect({
    required ComicTranslationManager manager,
    required String comicId,
    required String chapterKey,
    required int pageIndex,
    required String lang,
  }) async {
    if (pageIndex <= 0) return const <TranslationContextPair>[];
    final pages = <ComicPageTranslation>[];
    for (var i = pageIndex - 1;
        i >= 0 && pages.length < maxPages;
        i--) {
      try {
        final page = await manager.load(
          comicId: comicId,
          chapterKey: chapterKey,
          pageIndex: i,
          lang: lang,
        );
        if (page == null || page.isEmptyPage) continue;
        pages.add(page);
      } on Object {
        // 单页读取失败不影响上下文（缓存损坏按无上下文处理）。
      }
    }

    final pairs = <TranslationContextPair>[];
    for (final page in pages.reversed) {
      for (final segment in page.segments) {
        final source = segment.text.trim();
        final translation = segment.translation.trim();
        if (source.isEmpty || translation.isEmpty) continue;
        final issues = TranslationFaithfulness.issuesFor(
          source: source,
          translation: translation,
          targetLang: lang,
        );
        if (issues.isNotEmpty) continue;
        pairs.add((source: source, translation: translation));
      }
    }
    return _trim(pairs);
  }

  /// 从最旧一侧裁剪，保证对数和字符数不超预算。
  static List<TranslationContextPair> _trim(
    List<TranslationContextPair> pairs,
  ) {
    var start = 0;
    var chars = 0;
    for (final pair in pairs) {
      chars += pair.source.length + pair.translation.length;
    }
    while (start < pairs.length &&
        (pairs.length - start > maxPairs || chars > maxChars)) {
      chars -= pairs[start].source.length + pairs[start].translation.length;
      start++;
    }
    return pairs.sublist(start);
  }
}
