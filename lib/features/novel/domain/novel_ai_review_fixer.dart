/// 影子修订应用器（AI 审校修复闭环的最后一步）。
///
/// AI 审校产出的 [TranslationReviewFinding.revision] 只是影子修订，
/// 不直接写正式译文；用户逐条或批量采纳后由本类应用到章节缓存。
/// 应用保持原文与输入指纹不变（采纳修订不改变翻译输入），并推进
/// updatedAt；调用方负责在写回后失效该章润色槽。
library;

import '../../../core/novel/novel_review_manager.dart';
import '../../../core/novel/novel_translation_manager.dart';

/// 影子修订应用器（纯函数，无 IO）。
abstract final class NovelAiReviewFixer {
  /// 将采纳的修订应用到章节缓存记录，返回新的记录（原记录不变）。
  ///
  /// 忽略：空修订、他章发现、越界段落。指纹与原文保留，updatedAt 推进。
  static NovelChapterTranslation apply({
    required NovelChapterTranslation chapter,
    required List<TranslationReviewFinding> accepted,
  }) {
    final translations = List<String>.of(chapter.translations);
    var changed = false;
    for (final f in accepted) {
      if (f.chapterId != chapter.chapterId) continue;
      if (f.revision.trim().isEmpty) continue;
      if (f.paragraphIndex < 0 || f.paragraphIndex >= translations.length) {
        continue;
      }
      translations[f.paragraphIndex] = f.revision.trim();
      changed = true;
    }
    if (!changed) return chapter;
    return NovelChapterTranslation(
      novelId: chapter.novelId,
      chapterId: chapter.chapterId,
      chapterTitle: chapter.chapterTitle,
      lang: chapter.lang,
      translations: translations,
      sources: chapter.sources,
      fingerprint: chapter.fingerprint,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}
