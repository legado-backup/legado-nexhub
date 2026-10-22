/// 翻译审查页（多阶段质量：证据驱动审查）。
///
/// 每本有已缓存章节译文的书籍提供两条审查路径：
/// - 点书名行：本地零成本启发式审查（术语一致性/漏译/直译腔）；
/// - 行尾「AI 审校」按钮：云端逐段审校，产出带影子修订的发现，可在
///   报告底部逐条采纳（写回缓存）或忽略。
/// 报告存 Hive 并落 JSON 文件（nexhub/reviews/）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart'
    show AiEndpointConfig;
import 'package:nexhub/core/novel/novel_review_manager.dart';
import 'package:nexhub/core/novel/novel_translation_manager.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/widgets/app_animations.dart';
import '../../novel/domain/novel_ai_review_fixer.dart';
import '../../novel/domain/novel_ai_review_service.dart';
import '../../novel/domain/novel_review_service.dart';
import '../../novel/domain/novel_summary_settings.dart';
import '../../../core/widgets/app_glass_bar.dart';

class TranslationReviewScreen extends StatefulWidget {
  const TranslationReviewScreen({super.key});

  @override
  State<TranslationReviewScreen> createState() =>
      _TranslationReviewScreenState();
}

class _TranslationReviewScreenState extends State<TranslationReviewScreen> {
  final NovelTranslationManager _translations = NovelTranslationManager();
  final NovelReviewManager _reports = NovelReviewManager();
  final GlossaryManager _glossary = GlossaryManager();

  String _lang = 'zh';
  bool _loading = true;
  bool _reviewing = false;
  String? _aiReviewingId;
  int _aiDone = 0;
  int _aiTotal = 0;
  final Map<String, int> _chapterCounts = <String, int>{};
  final Map<String, int> _findingCounts = <String, int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _lang =
          await NovelSummarySettings.instance.getTranslationTargetLanguage();
      await _translations.init();
      await _reports.init();
      final books = await _translations.listNovelIds();
      final reviewed = await _reports.listReviewedNovelIds();
      final chapterCounts = <String, int>{};
      final findingCounts = <String, int>{};
      for (final id in books) {
        final chapters = await _translations.listForNovel(id, lang: _lang);
        chapterCounts[id] = chapters.length;
        if (reviewed.contains(id)) {
          final report = await _reports.load(id, lang: _lang);
          findingCounts[id] = report?.findings.length ?? 0;
        }
      }
      if (!mounted) return;
      setState(() {
        _chapterCounts
          ..clear()
          ..addAll(chapterCounts);
        _findingCounts
          ..clear()
          ..addAll(findingCounts);
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// 翻译端点（主 + 备用，baseUrl 为空的配置跳过）。
  Future<List<AiEndpointConfig>> _endpoints() async {
    final cfgs = await NovelSummarySettings.instance.getTranslationEndpoints();
    return <AiEndpointConfig>[
      for (final c in cfgs)
        if (c.baseUrl.trim().isNotEmpty)
          AiEndpointConfig(
            baseUrl: c.baseUrl,
            apiKey: c.apiKey,
            model: c.model,
          ),
    ];
  }

  Future<void> _reviewBook(String novelId) async {
    if (_reviewing || _aiReviewingId != null) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _reviewing = true);
    try {
      final chapters = await _translations.listForNovel(novelId, lang: _lang);
      var glossary = const <GlossaryEntry>[];
      try {
        glossary = await _glossary.effectiveEntries(novelId, _lang);
      } on Object {
        // 术语表不可用时跳过术语检查。
      }
      final findings = NovelReviewService.review(
        chapters: chapters,
        lang: _lang,
        glossary: glossary,
      );
      final truncated = findings.length > NovelReviewManager.summaryMaxFindings;
      final report = TranslationReviewReport(
        novelId: novelId,
        lang: _lang,
        novelTitle: novelId,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        chaptersReviewed: chapters.length,
        findings: truncated
            ? findings.take(NovelReviewManager.summaryMaxFindings).toList()
            : findings,
        truncated: truncated,
      );
      await _reports.save(report);
      // 摘要版同时落 JSON 文件（完整版，best-effort）。
      await NovelReviewManager.writeReportFile(report);
      if (!mounted) return;
      setState(() => _findingCounts[novelId] = report.findings.length);
      await _showReport(report);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.reviewRunFailed)),
      );
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }

  Future<void> _reviewBookAi(String novelId) async {
    if (_aiReviewingId != null || _reviewing) return;
    final l10n = AppLocalizations.of(context);
    final endpoints = await _endpoints();
    if (!mounted) return;
    if (endpoints.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.reviewRunFailed)),
      );
      return;
    }
    setState(() {
      _aiReviewingId = novelId;
      _aiDone = 0;
      _aiTotal = 0;
    });
    try {
      final chapters = await _translations.listForNovel(novelId, lang: _lang);
      // 无对齐原文的章节无法逐段审校，报告里也不计入。
      final reviewed = chapters
          .where((c) =>
              c.sources != null && c.sources!.length == c.translations.length)
          .length;
      var glossary = const <GlossaryEntry>[];
      try {
        glossary = await _glossary.effectiveEntries(novelId, _lang);
      } on Object {
        // 术语表不可用时跳过术语检查。
      }
      final outcome = await NovelAiReviewService().reviewChapters(
        chapters: chapters,
        lang: _lang,
        endpoints: endpoints,
        glossary: glossary,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _aiDone = done;
            _aiTotal = total;
          });
        },
      );
      final truncated =
          outcome.findings.length > NovelReviewManager.summaryMaxFindings;
      final report = TranslationReviewReport(
        novelId: novelId,
        lang: _lang,
        novelTitle: novelId,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        chaptersReviewed: reviewed,
        findings: truncated
            ? outcome.findings.take(NovelReviewManager.summaryMaxFindings).toList()
            : outcome.findings,
        truncated: truncated,
        engine: 'ai',
        partial: outcome.partial,
      );
      await _reports.save(report);
      await NovelReviewManager.writeReportFile(report);
      if (!mounted) return;
      setState(() => _findingCounts[novelId] = report.findings.length);
      await _showReport(report);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.reviewRunFailed)),
      );
    } finally {
      if (mounted) setState(() => _aiReviewingId = null);
    }
  }

  Future<void> _showReport(TranslationReviewReport report) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ReviewReportSheet(
        report: report,
        translations: _translations,
        lang: _lang,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final books = _chapterCounts.keys.toList();
    return AppShrinkTitleScaffold(
      title: Text(l10n.reviewTitle),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : books.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppTokens.spaceXl),
                    child: Text(
                      l10n.reviewBooksEmpty,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: context.pageInset(AppTokens.spaceLg),
                  itemCount: books.length,
                  itemBuilder: (context, i) {
                    final id = books[i];
                    final findings = _findingCounts[id];
                    return Card(
                      margin: const EdgeInsets.only(bottom: AppTokens.spaceSm),
                      child: ListTile(
                        title: Text(
                          id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          findings == null
                              ? l10n.reviewBookChapters(_chapterCounts[id] ?? 0)
                              : l10n.reviewBookFindings(findings),
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                        trailing: _reviewing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : _aiReviewingId == id
                                ? Text(
                                    l10n.reviewAiProgress(_aiDone, _aiTotal),
                                    style: TextStyle(
                                        fontSize: 12, color: scheme.primary),
                                  )
                                : TextButton(
                                    onPressed:
                                        (_reviewing || _aiReviewingId != null)
                                            ? null
                                            : () => _reviewBookAi(id),
                                    child: Text(l10n.reviewAiAction),
                                  ),
                        onTap: (_reviewing || _aiReviewingId != null)
                            ? null
                            : () => _reviewBook(id),
                      ),
                    );
                  },
                ),
    );
  }
}

/// 审查报告底部弹层：AI 报告支持逐条采纳（写回缓存）/ 忽略 / 全部应用。
class _ReviewReportSheet extends StatefulWidget {
  const _ReviewReportSheet({
    required this.report,
    required this.translations,
    required this.lang,
  });

  final TranslationReviewReport report;
  final NovelTranslationManager translations;
  final String lang;

  @override
  State<_ReviewReportSheet> createState() => _ReviewReportSheetState();
}

class _ReviewReportSheetState extends State<_ReviewReportSheet> {
  late final List<TranslationReviewFinding> _findings =
      List<TranslationReviewFinding>.of(widget.report.findings);
  bool _applying = false;

  /// 把采纳的影子修订写回章节缓存；返回实际应用的条数。
  Future<int> _apply(Iterable<TranslationReviewFinding> accepted) async {
    final targets =
        accepted.where((f) => f.revision.isNotEmpty).toList();
    if (targets.isEmpty) return 0;
    final byChapter = <String, List<TranslationReviewFinding>>{};
    for (final f in targets) {
      byChapter.putIfAbsent(f.chapterId, () => <TranslationReviewFinding>[]).add(f);
    }
    var applied = 0;
    for (final entry in byChapter.entries) {
      final chapter = await widget.translations.load(
          widget.report.novelId, entry.key,
          lang: widget.report.lang);
      if (chapter == null) continue;
      final fixed =
          NovelAiReviewFixer.apply(chapter: chapter, accepted: entry.value);
      if (identical(fixed, chapter)) continue;
      await widget.translations.save(fixed);
      // 修订后旧润色失效。
      await widget.translations.clearPolished(
          widget.report.novelId, entry.key,
          lang: widget.report.lang);
      applied += entry.value.length;
    }
    if (!mounted) return applied;
    if (applied > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                AppLocalizations.of(context).reviewAppliedCount(applied))),
      );
    }
    return applied;
  }

  Future<void> _accept(TranslationReviewFinding f) async {
    await _apply(<TranslationReviewFinding>[f]);
    if (!mounted) return;
    setState(() => _findings.remove(f));
  }

  Future<void> _acceptAll() async {
    if (_applying) return;
    setState(() => _applying = true);
    try {
      final revisable =
          _findings.where((f) => f.revision.isNotEmpty).toList();
      await _apply(revisable);
      if (!mounted) return;
      setState(() => _findings.removeWhere(revisable.contains));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Widget _chip(String label, ColorScheme scheme, TextTheme text,
      {bool highlight = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceSm, vertical: AppTokens.spaceXxs),
      decoration: BoxDecoration(
        color: highlight ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      ),
      child: Text(label, style: text.labelMedium),
    );
  }

  Widget _typeChip(
      TranslationReviewFinding f, AppLocalizations l10n, ColorScheme scheme, TextTheme text) {
    final label = switch (f.type) {
      ReviewFindingType.glossary => l10n.reviewTypeGlossary,
      ReviewFindingType.missing => l10n.reviewTypeMissing,
      ReviewFindingType.literal => l10n.reviewTypeLiteral,
      ReviewFindingType.added => l10n.reviewTypeAdded,
      ReviewFindingType.mistranslation => l10n.reviewTypeMistranslation,
      ReviewFindingType.terminology => l10n.reviewTypeTerminology,
      ReviewFindingType.pronoun => l10n.reviewTypePronoun,
      _ => f.type,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _chip(label, scheme, text),
        if (f.engine == 'ai') ...<Widget>[
          const SizedBox(width: AppTokens.spaceXs),
          _chip('AI', scheme, text, highlight: true),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final revisable = _findings.any((f) => f.revision.isNotEmpty);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      l10n.reviewTitle,
                      style: text.titleMedium,
                    ),
                  ),
                  Text(
                    l10n.reviewFindingCount(_findings.length),
                    style: text.bodySmall?.copyWith(color: scheme.outline),
                  ),
                  if (revisable && !_applying) ...<Widget>[
                    const SizedBox(width: AppTokens.spaceSm),
                    TextButton(
                      onPressed: _acceptAll,
                      child: Text(l10n.reviewApplyAll),
                    ),
                  ],
                  if (_applying)
                    const Padding(
                      padding: EdgeInsets.only(left: AppTokens.spaceSm),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                ],
              ),
            ),
            if (widget.report.partial)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
                child: Text(
                  l10n.reviewAiPartial,
                  style: text.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            if (widget.report.truncated)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
                child: Text(
                  l10n.reviewTruncated,
                  style: text.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: _findings.isEmpty
                  ? Center(child: Text(l10n.reviewNoFindings))
                  : ListView.builder(
                      padding: const EdgeInsets.all(AppTokens.spaceMd),
                      itemCount: _findings.length,
                      itemBuilder: (context, i) {
                        final f = _findings[i];
                        return Card(
                          margin: const EdgeInsets.only(
                              bottom: AppTokens.spaceSm),
                          child: Padding(
                            padding: const EdgeInsets.all(AppTokens.spaceSm),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    _typeChip(f, l10n, scheme, text),
                                    const SizedBox(width: AppTokens.spaceSm),
                                    Expanded(
                                      child: Text(
                                        '${f.chapterTitle} · #${f.paragraphIndex + 1}',
                                        style: text.labelMedium,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: AppTokens.spaceXs),
                                Text(f.detail, style: text.bodySmall),
                                if (f.source.isNotEmpty) ...<Widget>[
                                  const SizedBox(height: AppTokens.spaceXs),
                                  Text(f.source,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: text.bodySmall
                                          ?.copyWith(height: 1.4)),
                                ],
                                if (f.translation.isNotEmpty) ...<Widget>[
                                  const SizedBox(height: 2),
                                  Text(
                                    f.translation,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.bodySmall?.copyWith(
                                        height: 1.4, color: scheme.primary),
                                  ),
                                ],
                                if (f.revision.isNotEmpty) ...<Widget>[
                                  const SizedBox(height: AppTokens.spaceXs),
                                  Text(
                                    l10n.reviewRevision,
                                    style: text.labelMedium
                                        ?.copyWith(color: scheme.primary),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    f.revision,
                                    maxLines: 6,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.bodySmall
                                        ?.copyWith(height: 1.4),
                                  ),
                                  const SizedBox(height: AppTokens.spaceXs),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: <Widget>[
                                      TextButton(
                                        onPressed: () =>
                                            setState(() => _findings.remove(f)),
                                        child: Text(l10n.reviewIgnore),
                                      ),
                                      TextButton(
                                        onPressed: () => _accept(f),
                                        child: Text(l10n.reviewAccept),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
