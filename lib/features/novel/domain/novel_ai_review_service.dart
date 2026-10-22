/// 逐块 AI 审校（多阶段质量：证据驱动的模型复审）。
///
/// 对已缓存章节译文按块（16 段）发起审校请求：证据一次打包（原文+译文+
/// 命中术语+邻段上下文），不做 agentic 多轮查询。问题类型限定
/// 漏译/过度翻译/误译/术语不一致/指代错误，每条附建议与影子修订
/// （不直接写正式译文，采纳后由 [NovelAiReviewFixer] 应用）。
///
/// 成本与稳定性约束：
/// - 仅手动触发，逐块串行并回报进度；
/// - 单块失败重试 1 次，仍失败则跳过该块并标记 partial，不中断全书；
/// - 无原文对齐的旧缓存章节直接跳过（模型审查需要证据对照）。
library;

import 'package:dio/dio.dart';

import '../../../core/ai/ai_chat_client.dart';
import '../../../core/ai/glossary_manager.dart';
import '../../../core/ai/glossary_matcher.dart';
import '../../../core/ai/prompt_builder.dart';
import '../../../core/ai/translation_exception.dart';
import '../../../core/ai/vision_translation_client.dart' show AiEndpointConfig;
import '../../../core/novel/novel_review_manager.dart';
import '../../../core/novel/novel_translation_manager.dart';
import '../../../core/utils/app_log.dart';

/// AI 审校结果。
class AiReviewOutcome {
  /// 全部成功的块产出的发现（跳过的块无发现）。
  final List<TranslationReviewFinding> findings;

  /// true = 有块重试后仍失败被跳过，报告可能不完整。
  final bool partial;
  final int chunksTotal;
  final int chunksDone;

  const AiReviewOutcome({
    required this.findings,
    required this.partial,
    required this.chunksTotal,
    required this.chunksDone,
  });
}

/// 逐块 AI 审校服务。
class NovelAiReviewService {
  NovelAiReviewService({Dio? dio, AiChatClient? client})
      : _client = client ?? AiChatClient(dio: dio);

  final AiChatClient _client;

  /// 单块段落数上限：块太大证据挤占提示词，太小请求数翻倍。
  static const int chunkSize = 16;

  /// 每块最多携带的邻段（前文）上下文对数。
  static const int _maxNeighborSegments = 2;

  static const int _maxSuggestionChars = 300;
  static const int _maxRevisionChars = 4000;

  static const Map<String, String> _typeAliases = <String, String>{
    'missing': ReviewFindingType.missing,
    '漏译': ReviewFindingType.missing,
    'added': ReviewFindingType.added,
    '增译': ReviewFindingType.added,
    '过度翻译': ReviewFindingType.added,
    'mistranslation': ReviewFindingType.mistranslation,
    '误译': ReviewFindingType.mistranslation,
    'terminology': ReviewFindingType.terminology,
    '术语': ReviewFindingType.terminology,
    '术语不一致': ReviewFindingType.terminology,
    'pronoun': ReviewFindingType.pronoun,
    '指代': ReviewFindingType.pronoun,
    '指代错误': ReviewFindingType.pronoun,
  };

  /// 审校整书已缓存译文（有原文对齐的章节）。
  Future<AiReviewOutcome> reviewChapters({
    required List<NovelChapterTranslation> chapters,
    required String lang,
    required List<AiEndpointConfig> endpoints,
    List<GlossaryEntry> glossary = const <GlossaryEntry>[],
    void Function(int done, int total)? onProgress,
  }) async {
    if (endpoints.isEmpty) {
      throw const TranslationException('未配置云端 AI 接口');
    }
    var chunksTotal = 0;
    for (final ch in chapters) {
      chunksTotal += _chunkCount(ch);
    }
    final findings = <TranslationReviewFinding>[];
    var partial = false;
    var chunksDone = 0;
    for (final ch in chapters) {
      final sources = ch.sources;
      final total = ch.translations.length;
      if (sources == null || sources.length != total) continue;
      for (var start = 0; start < total; start += chunkSize) {
        final end = (start + chunkSize).clamp(0, total);
        final chunkFindings = await _reviewChunkWithRetry(
          chapter: ch,
          lang: lang,
          endpoints: endpoints,
          glossary: glossary,
          sources: sources.sublist(start, end),
          translations: ch.translations.sublist(start, end),
          startIndex: start,
          neighbors: _neighbors(sources, ch.translations, start),
        );
        if (chunkFindings == null) {
          partial = true;
          AppLog.instance
              .w('[AI 审校] ${ch.chapterTitle} 段落 $start-$end 跳过');
        } else {
          findings.addAll(chunkFindings);
        }
        chunksDone++;
        onProgress?.call(chunksDone, chunksTotal);
      }
    }
    return AiReviewOutcome(
      findings: findings,
      partial: partial,
      chunksTotal: chunksTotal,
      chunksDone: chunksDone,
    );
  }

  static int _chunkCount(NovelChapterTranslation ch) {
    final sources = ch.sources;
    if (sources == null || sources.length != ch.translations.length) return 0;
    final n = ch.translations.length;
    return (n + chunkSize - 1) ~/ chunkSize;
  }

  /// 块前的邻段上下文（原文+译文对，最多 2 对）。
  static List<({String source, String translation})> _neighbors(
    List<String> sources,
    List<String> translations,
    int start,
  ) {
    final result = <({String source, String translation})>[];
    for (var i = start - 1;
        i >= 0 && result.length < _maxNeighborSegments;
        i--) {
      final src = sources[i].trim();
      final tr = translations[i].trim();
      if (src.isEmpty || tr.isEmpty) continue;
      result.add((source: src, translation: tr));
    }
    return result.reversed.toList();
  }

  /// 单块审校：失败重试 1 次；仍失败返回 null（跳过该块）。
  Future<List<TranslationReviewFinding>?> _reviewChunkWithRetry({
    required NovelChapterTranslation chapter,
    required String lang,
    required List<AiEndpointConfig> endpoints,
    required List<GlossaryEntry> glossary,
    required List<String> sources,
    required List<String> translations,
    required int startIndex,
    required List<({String source, String translation})> neighbors,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _reviewChunkOnce(
          chapter: chapter,
          lang: lang,
          endpoints: endpoints,
          glossary: glossary,
          sources: sources,
          translations: translations,
          startIndex: startIndex,
          neighbors: neighbors,
        );
      } on Object catch (e) {
        if (attempt == 1) return null;
        AppLog.instance.w('[AI 审校] 块请求失败，重试: $e');
      }
    }
    return null;
  }

  Future<List<TranslationReviewFinding>> _reviewChunkOnce({
    required NovelChapterTranslation chapter,
    required String lang,
    required List<AiEndpointConfig> endpoints,
    required List<GlossaryEntry> glossary,
    required List<String> sources,
    required List<String> translations,
    required int startIndex,
    required List<({String source, String translation})> neighbors,
  }) async {
    final scoped = GlossaryMatcher.entriesInTexts(glossary, sources);
    final decoded = await _client.completeJson(
      endpoints,
      system: buildSystemPrompt(lang, glossary: scoped),
      user: buildUserPrompt(
        sources: sources,
        translations: translations,
        neighbors: neighbors,
      ),
      temperature: 0.1,
      maxTokens: 2000,
    );
    final issues = _decodeIssues(decoded);
    if (issues == null) {
      throw const TranslationException('审校输出格式异常');
    }
    return _toFindings(
      chapter: chapter,
      sources: sources,
      translations: translations,
      startIndex: startIndex,
      issues: issues,
    );
  }

  /// 容错解码：接受 JSON 数组或含 issues/findings 键的对象。
  static List<Map<String, dynamic>>? _decodeIssues(dynamic decoded) {
    if (decoded is List) {
      return <Map<String, dynamic>>[
        for (final e in decoded)
          if (e is Map<String, dynamic>) e,
      ];
    }
    if (decoded is Map) {
      final list = decoded['issues'] ?? decoded['findings'];
      if (list is List) {
        return <Map<String, dynamic>>[
          for (final e in list)
            if (e is Map<String, dynamic>) e,
        ];
      }
    }
    return null;
  }

  static List<TranslationReviewFinding> _toFindings({
    required NovelChapterTranslation chapter,
    required List<String> sources,
    required List<String> translations,
    required int startIndex,
    required List<Map<String, dynamic>> issues,
  }) {
    final result = <TranslationReviewFinding>[];
    for (final issue in issues) {
      final idx = (issue['index'] as num?)?.toInt() ?? -1;
      final i = idx - 1; // 提示词使用 1 基段落号。
      if (i < 0 || i >= sources.length) continue;
      final rawType = (issue['type'] as String? ?? '').trim();
      final type = _typeAliases[rawType] ?? _typeAliases[rawType.toLowerCase()];
      if (type == null) continue;
      result.add(TranslationReviewFinding(
        type: type,
        chapterId: chapter.chapterId,
        chapterTitle: chapter.chapterTitle,
        paragraphIndex: startIndex + i,
        source: sources[i],
        translation: translations[i],
        detail: _clamp(issue['detail'] as String? ?? '', 300),
        engine: 'ai',
        suggestion: _clamp(issue['suggestion'] as String? ?? '', _maxSuggestionChars),
        revision: _clamp(issue['revision'] as String? ?? '', _maxRevisionChars),
      ));
    }
    return result;
  }

  static String _clamp(String text, int maxChars) {
    final t = text.trim();
    return t.length <= maxChars ? t : t.substring(0, maxChars);
  }

  /// 审校 system prompt（类型限定 + 输出协议）。
  static String buildSystemPrompt(
    String lang, {
    List<GlossaryEntry> glossary = const <GlossaryEntry>[],
  }) {
    final buf = StringBuffer()
      ..write('你是专业的小说翻译审校。用户会给出若干编号段落的「原文与译文」，'
          '目标语言：$lang。请逐段比对审查，只报告有明确依据的问题，宁缺毋滥。'
          '问题类型限定为：\n'
          '- missing：漏译（原文有实质内容而译文缺失或明显缺成分）\n'
          '- added：过度翻译（译文增添了原文没有的情节或信息）\n'
          '- mistranslation：误译（语义错误、逻辑颠倒、语气曲解）\n'
          '- terminology：术语不一致（与术语表或上下文既定译名不符）\n'
          '- pronoun：指代错误\n'
          '输出严格 JSON 数组，不要输出解释或代码块标记。每项格式：\n'
          '{"index": 段落号, "type": "missing|added|mistranslation|terminology|pronoun", '
          '"detail": "一句话说明问题", "suggestion": "修改建议", '
          '"revision": "修订后的完整段落译文"}\n'
          'index 对应输入段落号；revision 必须是可直接替换原段的完整译文，'
          '仅在确有把握时给出，否则用空串；detail 与 suggestion 使用目标语言；'
          '没有问题时输出 []。');
    final glossaryText = PromptBuilder.glossarySection(glossary);
    if (glossaryText.isNotEmpty) {
      buf.write('\n$glossaryText');
    }
    return buf.toString();
  }

  /// 审校 user prompt（邻段上下文 + 编号原文/译文对）。
  static String buildUserPrompt({
    required List<String> sources,
    required List<String> translations,
    List<({String source, String translation})> neighbors =
        const <({String source, String translation})>[],
  }) {
    final buf = StringBuffer();
    if (neighbors.isNotEmpty) {
      buf.write('【邻段上下文（仅供参考，不审查）】\n');
      for (final n in neighbors) {
        buf
          ..writeln('原文：${n.source}')
          ..writeln('译文：${n.translation}\n');
      }
    }
    buf.write('【审查段落】');
    for (var i = 0; i < sources.length; i++) {
      buf
        ..writeln()
        ..writeln('段落${i + 1}')
        ..writeln('原文：${sources[i]}')
        ..writeln('译文：${translations[i]}');
    }
    return buf.toString();
  }
}
