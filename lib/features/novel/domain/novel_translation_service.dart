/// 小说段落翻译服务（双语/段落翻译）。
///
/// 复用 AI 统一配置（[NovelSummarySettings]）：
/// - **翻译级独立接口**优先（AI 配置页），baseUrl 为空时回落通用配置；
/// - 目标语言 / 分块大小读取翻译配置页的设置；
/// - **批量优先**：全部段落以 `<<<N>>>` 序号分隔拼成一次请求，解析回逐段译文
/// （省 token、快）；协议编解码统一走 [BatchProtocol]（收敛单份实现）；
/// - **预算保护**：段落数超过 [_kOneShotMaxParagraphs] 时直接跳过
/// 整章 one-shot 进入分块——超大章的整章请求几乎必被输出上限截断，
/// 先试再败只会白付一次大请求的 token/延迟；
/// - **分块回退**：批量解析段数不齐 / 请求失败时按 [batchSize] 分块重试；
/// - **术语表与提示词**：system prompt 由 [PromptBuilder] 组装
/// （按本批出现过滤的术语表 + 风格预设 + CoT + 作品语境），
/// 术语冲突在响应侧检测入日志；
/// - **衔接上下文**：块间携带 [RollingContext] 的尾部原文+译文，
/// 并预读下一段原文帮助判断段末断句；跨章可由调用方传入前章尾部；
/// - **断点续译**：[existing] 传入已完成的部分译文（空串 = 待译），
/// 已完成块直接复用不发请求；[onChunkPersisted] 供调用方逐块落盘检查点；
/// - 译文由调用方经 [NovelTranslationManager] 持久化（导出附带同源）。
library;

import 'package:dio/dio.dart';

import '../../../core/ai/batch_protocol.dart';
import '../../../core/ai/bing_translation_client.dart';
import '../../../core/ai/endpoint_router.dart';
import '../../../core/ai/vision_translation_client.dart' show AiEndpointConfig;
import '../../../core/ai/glossary_extractor.dart';
import '../../../core/ai/glossary_manager.dart';
import '../../../core/ai/glossary_matcher.dart';
import '../../../core/ai/prompt_builder.dart';
import '../../../core/ai/rolling_context.dart';
import '../../../core/ai/translation_engine_policy.dart';
import '../../../core/ai/translation_exception.dart';
import '../../../core/ai/translation_feature_flags.dart';
import '../../../core/ai/translation_language.dart';
import '../../../core/ai/translation_options_store.dart';
import '../../../core/ai/vision_translation_client.dart' show TranslationContextPair;
import '../../../core/utils/app_log.dart';
import '../../../../core/novel/novel_translation_manager.dart';
import 'novel_summary_settings.dart';

/// 段落翻译服务。
class NovelTranslationService {
  NovelTranslationService({
    Dio? dio,
    NovelSummarySettings? settings,
    String? targetLanguage,
    GlossaryManager? glossary,
    TranslationOptionsStore? options,
    BingTranslationClient? bingClient,
    GlossaryExtractor? extractor,
  })  : _dio = dio ?? Dio(),
        _settings = settings ?? NovelSummarySettings.instance,
        _targetLanguage = targetLanguage,
        _glossary = glossary ?? GlossaryManager(),
        _options = options ?? TranslationOptionsStore(),
        _bing = bingClient ?? BingTranslationClient(),
        _extractor = extractor;

  final Dio _dio;
  final NovelSummarySettings _settings;
  final GlossaryManager _glossary;
  final TranslationOptionsStore _options;
  final BingTranslationClient _bing;

  /// 术语提取器（null 时按需创建，复用本服务的 Dio 配置）。
  GlossaryExtractor? _extractor;

  GlossaryExtractor get _glossaryExtractor =>
      _extractor ??= GlossaryExtractor(dio: _dio);

  /// 翻译目标语言（提示词用，默认中文）；null 时运行时读翻译配置页设置。
  final String? _targetLanguage;

  /// 单次请求的段落数上限：超过直接分块，避免必然截断的超大请求。
  static const int _kOneShotMaxParagraphs = 40;

  /// 精译单块段落数上限：三稿并发成本随块大小线性放大，块不宜过大。
  static const int _kRefinedMaxChunk = 8;

  /// 精译三稿的采样温度：低温求稳、中温均衡、高温求表达多样。
  static const List<double> _kRefinedTemperatures = <double>[0.2, 0.5, 0.8];

  /// 批量协议编码（兼容旧入口；实现收敛于 [BatchProtocol]）。
  static String encodeBatch(List<String> paragraphs) =>
      BatchProtocol.encode(paragraphs);

  /// 批量协议解析（兼容旧入口；实现收敛于 [BatchProtocol]）。
  static List<String>? parseBatched(String raw, int expected) =>
      BatchProtocol.decode(raw, expected);

  /// 翻译整个段落列表。返回与输入等长的译文列表（失败抛异常，由 UI 展示）。
  ///
  /// [onProgress] 回调 (已完成段数, 总数)，供长章节显示进度；
  /// [workId] 用于术语表 / 风格的作品级配置（null 时用全局）；
  /// [existing] 为断点续译的已完成译文（与 [paragraphs] 等长，
  /// 空串表示待译）；[onChunkPersisted] 在每个分块完成后回调当前完整
  /// 译文快照，供调用方落盘检查点；[bookContext] 为 全书概述注入；
  /// [previousChapterContext] 为前一章尾部原文+译文（跨章衔接，可空）。
  ///
  /// 自动术语提取仅在 [workId] 非空且设置开启时运行：每块翻译完成后
  /// 追加一次小请求，新词/别名落库、异译记冲突；失败静默跳过。
  /// [chapterId]/[chapterTitle]/[chapterIndex] 仅用于冲突出处展示；
  /// [onGlossaryExtracted] 逐块回调收录统计，供面板展示状态。
  Future<List<String>> translateParagraphs(
    List<String> paragraphs, {
    int? batchSize,
    void Function(int done, int total)? onProgress,
    String? workId,
    List<String> existing = const <String>[],
    void Function(List<String> translatedSoFar)? onChunkPersisted,
    String? bookContext,
    List<TranslationContextPair> previousChapterContext =
        const <TranslationContextPair>[],
    String? chapterId,
    String? chapterTitle,
    int? chapterIndex,
    void Function(GlossaryUpsertSummary summary)? onGlossaryExtracted,
  }) async {
    if (paragraphs.isEmpty) return const <String>[];
    final lang =
        _targetLanguage ?? await _settings.getTranslationTargetLanguage();
    final chunkSize =
        batchSize ?? await _settings.getTranslationBatchSize();

    // 术语表（作品级回落全局）、风格（作品级覆盖全局）、CoT 开关。
    // 任一读取失败都按「无术语 + 标准风格」降级，不影响翻译主流程。
    var glossary = const <GlossaryEntry>[];
    var style = TranslationStyle.standard;
    var cot = false;
    var autoExtract = false;
    var refined = false;
    final extractScope = workId?.trim() ?? '';
    try {
      glossary = await _glossary.effectiveEntries(workId, lang);
      style = await _options.effectiveStyle(workId);
      cot = await _options.getCotEnabled();
      refined = await _options.getRefinedEnabled();
      if (extractScope.isNotEmpty) {
        autoExtract = await _options.getAutoExtractEnabled();
      }
    } on Object {
      AppLog.instance.w('[小说翻译] 术语表/风格读取失败，按默认注入');
    }

    // 已完成的段落（existing 非空段）直接复用。
    final result = List<String>.generate(
      paragraphs.length,
      (i) => i < existing.length ? existing[i] : '',
    );
    var done = result.where((t) => t.isNotEmpty).length;
    final hasPartial = done > 0;
    if (done >= paragraphs.length) {
      onProgress?.call(done, paragraphs.length);
      return result;
    }
    onProgress?.call(done, paragraphs.length);

    final flags = TranslationFeatureFlags.instance;
    await flags.ensureLoaded();
    final advanced = TranslationEnginePolicy.advanced(
      hasGlossary: glossary.isNotEmpty,
      nonStandardStyle: style != TranslationStyle.standard,
      cot: cot,
    );
    final order = TranslationEnginePolicy.order(
      bingEnabled: flags.bingEnabled,
      preferBing: flags.bingFirst,
      advancedOptions: advanced,
    );
    final bingAvailable =
        flags.bingEnabled && TranslationLanguage.bingCode(lang) != null;

    // 主 + 备用端点（功能级回落通用），失败路由在请求层执行。
    final endpointCfgs = await _settings.getTranslationEndpoints();
    final endpoints = <AiEndpointConfig>[
      for (final c in endpointCfgs)
        if (c.baseUrl.trim().isNotEmpty)
          AiEndpointConfig(
            baseUrl: c.baseUrl,
            apiKey: c.apiKey,
            model: c.model,
          ),
    ];

    Future<void> runBing() => _bingPass(
          paragraphs: paragraphs,
          result: result,
          lang: lang,
          onProgress: onProgress,
          onChunkPersisted: onChunkPersisted,
        );

    Future<void> runAi() => _aiPass(
          paragraphs: paragraphs,
          result: result,
          endpoints: endpoints,
          lang: lang,
          chunkSize: chunkSize,
          allowOneShot: batchSize == null,
          hasPartial: hasPartial || _doneCount(paragraphs, result) > 0,
          glossary: glossary,
          style: style,
          cot: cot,
          refined: refined,
          bookContext: bookContext,
          previousChapterContext: previousChapterContext,
          workId: extractScope,
          autoExtract: autoExtract,
          chapterId: chapterId,
          chapterTitle: chapterTitle,
          chapterIndex: chapterIndex,
          onGlossaryExtracted: onGlossaryExtracted,
          onProgress: onProgress,
          onChunkPersisted: onChunkPersisted,
        );

    if (order == TranslationEngineOrder.bingFirst && bingAvailable) {
      try {
        await runBing();
        if (_allDone(paragraphs, result)) {
          onProgress?.call(paragraphs.length, paragraphs.length);
          return result;
        }
      } on Object catch (e) {
        AppLog.instance.w('[小说翻译] Bing 失败，转 AI 续跑: $e');
      }
    }

    if (endpoints.isNotEmpty) {
      try {
        await runAi();
        return result;
      } on Object catch (e) {
        if (order == TranslationEngineOrder.aiFirst &&
            bingAvailable &&
            !_allDone(paragraphs, result)) {
          AppLog.instance.w('[小说翻译] AI 失败，转 Bing 续跑: $e');
          await runBing();
          return result;
        }
        rethrow;
      }
    }

    if (bingAvailable && order == TranslationEngineOrder.aiFirst) {
      await runBing();
      return result;
    }
    if (_allDone(paragraphs, result)) return result;
    throw const TranslationException('未配置 AI 接口，且 Bing 免费翻译不可用');
  }

  static bool _isDone(List<String> paragraphs, List<String> result, int i) =>
      paragraphs[i].trim().isEmpty || result[i].trim().isNotEmpty;

  static int _doneCount(List<String> paragraphs, List<String> result) {
    var done = 0;
    for (var i = 0; i < paragraphs.length; i++) {
      if (_isDone(paragraphs, result, i)) done++;
    }
    return done;
  }

  static bool _allDone(List<String> paragraphs, List<String> result) =>
      _doneCount(paragraphs, result) >= paragraphs.length;

  /// Bing 免费翻译 pass：按批量上限切片，逐块进度与检查点；
  /// 同语言 / 空段落直接保留原文。
  Future<void> _bingPass({
    required List<String> paragraphs,
    required List<String> result,
    required String lang,
    void Function(int done, int total)? onProgress,
    void Function(List<String> translatedSoFar)? onChunkPersisted,
  }) async {
    var start = 0;
    while (start < paragraphs.length) {
      if (_isDone(paragraphs, result, start)) {
        start++;
        continue;
      }
      var end = start;
      var chars = 0;
      while (end < paragraphs.length) {
        if (!_isDone(paragraphs, result, end)) {
          final len = paragraphs[end].length;
          if (end > start &&
              (end - start >= BingTranslationClient.maxBatchItems ||
                  chars + len > BingTranslationClient.maxBatchChars)) {
            break;
          }
          chars += len;
        }
        end++;
      }
      final indexes = <int>[];
      final texts = <String>[];
      for (var i = start; i < end; i++) {
        if (_isDone(paragraphs, result, i)) continue;
        if (!TranslationLanguage.shouldTranslate(paragraphs[i], lang)) {
          result[i] = paragraphs[i];
          continue;
        }
        indexes.add(i);
        texts.add(paragraphs[i]);
      }
      if (texts.isNotEmpty) {
        final translated = await _bing.translate(
          texts: texts,
          targetLang: lang,
        );
        for (var i = 0; i < texts.length; i++) {
          final text = translated[i].trim();
          result[indexes[i]] = text.isEmpty ? texts[i] : text;
        }
      }
      onChunkPersisted?.call(List<String>.of(result));
      onProgress?.call(_doneCount(paragraphs, result), paragraphs.length);
      start = end;
    }
  }

  /// AI pass：保留原有 one-shot / 分块回退 / 术语与语境注入逻辑，
  /// 只对未完成段落发请求；精译开启时逐块走三稿合成。
  Future<void> _aiPass({
    required List<String> paragraphs,
    required List<String> result,
    required List<AiEndpointConfig> endpoints,
    required String lang,
    required int chunkSize,
    required bool allowOneShot,
    required bool hasPartial,
    required List<GlossaryEntry> glossary,
    required TranslationStyle style,
    required bool cot,
    required bool refined,
    required String? bookContext,
    List<TranslationContextPair> previousChapterContext =
        const <TranslationContextPair>[],
    String? workId,
    bool autoExtract = false,
    String? chapterId,
    String? chapterTitle,
    int? chapterIndex,
    void Function(GlossaryUpsertSummary summary)? onGlossaryExtracted,
    void Function(int done, int total)? onProgress,
    void Function(List<String> translatedSoFar)? onChunkPersisted,
  }) async {
    var currentGlossary = glossary;
    // 精译按固定小块发三稿并发，块上限收紧；整章 one-shot 跳过。
    final effectiveChunk =
        refined && chunkSize > _kRefinedMaxChunk ? _kRefinedMaxChunk : chunkSize;
    // 1) 整章一次批量（最省 token）；超大章或已有断点直接跳过，
    //    必然截断的请求不值得先付一次 token/延迟；失败/解析不齐 → 分块回退。
    final bool tryOneShot = !refined &&
        allowOneShot &&
        paragraphs.length <= _kOneShotMaxParagraphs &&
        !hasPartial &&
        !_allDone(paragraphs, result);
    if (tryOneShot) {
      try {
        final oneShot = await _requestBatch(
          paragraphs,
          endpoints,
          lang,
          glossary: currentGlossary,
          style: style,
          cot: cot,
          bookContext: bookContext,
          recentTranslations: previousChapterContext,
        );
        final parsed = parseBatched(oneShot, paragraphs.length);
        if (parsed != null) {
          _detectGlossaryConflicts(currentGlossary, paragraphs, parsed);
          for (var i = 0; i < result.length; i++) {
            if (!_isDone(paragraphs, result, i)) result[i] = parsed[i];
          }
          final summary = await _maybeExtract(
            endpoints: endpoints,
            lang: lang,
            workId: workId,
            autoExtract: autoExtract,
            sources: paragraphs,
            translations: parsed,
            glossary: currentGlossary,
            chapterId: chapterId,
            chapterTitle: chapterTitle,
            chapterIndex: chapterIndex,
          );
          if (summary != null) {
            onGlossaryExtracted?.call(summary);
            if (summary.changed > 0) {
              currentGlossary = await _reloadGlossary(
                workId,
                lang,
                fallback: currentGlossary,
              );
            }
          }
          onProgress?.call(paragraphs.length, paragraphs.length);
          onChunkPersisted?.call(List<String>.of(result));
          return;
        }
      } on Object catch (e) {
        AppLog.instance.w('[小说翻译] 整章批量失败，转入分块回退: $e');
      }
    }

    // 2) 分块翻译（每块 effectiveChunk 段，块内仍走批量协议）。
    // 整块已完成直接跳过，不重复请求；滚动上下文含前章尾部与本章已译段。
    final rolling = RollingContext(seed: previousChapterContext);
    var contextCursor = 0;
    for (var start = 0;
        start < paragraphs.length;
        start += effectiveChunk) {
      final end = (start + effectiveChunk).clamp(0, paragraphs.length);
      for (; contextCursor < start; contextCursor++) {
        rolling.add(paragraphs[contextCursor], result[contextCursor]);
      }
      final fullyDone = <bool>[
        for (var i = start; i < end; i++) _isDone(paragraphs, result, i),
      ].every((done) => done);
      if (!fullyDone) {
        final pendingIndexes = <int>[];
        final pendingTexts = <String>[];
        for (var i = start; i < end; i++) {
          if (_isDone(paragraphs, result, i)) continue;
          pendingIndexes.add(i);
          pendingTexts.add(paragraphs[i]);
        }
        if (pendingTexts.isNotEmpty) {
          final recent = rolling.render();
          final nextSource = _nextNonEmpty(paragraphs, end);
          // 精译：三稿并发 + 合成；草稿全败返回 null 走普通单译。
          List<String>? parsed = refined
              ? await _refinedChunk(
                  texts: pendingTexts,
                  endpoints: endpoints,
                  lang: lang,
                  glossary: currentGlossary,
                  style: style,
                  cot: cot,
                  bookContext: bookContext,
                  recentTranslations: recent,
                  nextSource: nextSource,
                )
              : null;
          parsed ??= await _plainChunk(
            pendingTexts,
            endpoints,
            lang,
            glossary: currentGlossary,
            style: style,
            cot: cot,
            bookContext: bookContext,
            recentTranslations: recent,
            nextSource: nextSource,
          );
          _detectGlossaryConflicts(currentGlossary, pendingTexts, parsed);
          for (var i = 0; i < pendingTexts.length; i++) {
            result[pendingIndexes[i]] = parsed[i];
          }
          // 术语提取在本块落盘前完成：后续块立即使用新词，冲突进待裁决。
          final summary = await _maybeExtract(
            endpoints: endpoints,
            lang: lang,
            workId: workId,
            autoExtract: autoExtract,
            sources: pendingTexts,
            translations: parsed,
            glossary: currentGlossary,
            chapterId: chapterId,
            chapterTitle: chapterTitle,
            chapterIndex: chapterIndex,
          );
          if (summary != null) {
            onGlossaryExtracted?.call(summary);
            if (summary.changed > 0) {
              currentGlossary = await _reloadGlossary(
                workId,
                lang,
                fallback: currentGlossary,
              );
            }
          }
        }
      }
      onProgress?.call(_doneCount(paragraphs, result), paragraphs.length);
      onChunkPersisted?.call(List<String>.of(result));
    }
  }

  /// 普通单译块：批量协议请求 + 解析（解析失败抛异常走外层回退）。
  Future<List<String>> _plainChunk(
    List<String> texts,
    List<AiEndpointConfig> endpoints,
    String lang, {
    required List<GlossaryEntry> glossary,
    required TranslationStyle style,
    required bool cot,
    required String? bookContext,
    required List<TranslationContextPair> recentTranslations,
    required String? nextSource,
  }) async {
    final raw = await _requestBatch(
      texts,
      endpoints,
      lang,
      glossary: glossary,
      style: style,
      cot: cot,
      bookContext: bookContext,
      recentTranslations: recentTranslations,
      nextSource: nextSource,
    );
    return parseBatched(raw, texts.length) ??
        (throw const TranslationException('翻译返回格式异常'));
  }

  /// 精译单块：三路草稿并发（不同温度）→ 综合合成。
  ///
  /// 降级链：部分草稿失败 → 用剩余草稿合成；仅剩一稿 → 直接采用不合成；
  /// 草稿全败 → 返回 null 由调用方走普通单译；合成失败/不可解析 → 取第一稿。
  Future<List<String>?> _refinedChunk({
    required List<String> texts,
    required List<AiEndpointConfig> endpoints,
    required String lang,
    required List<GlossaryEntry> glossary,
    required TranslationStyle style,
    required bool cot,
    required String? bookContext,
    required List<TranslationContextPair> recentTranslations,
    required String? nextSource,
  }) async {
    final drafts = await Future.wait<List<String>?>(<Future<List<String>?>>[
      for (final temp in _kRefinedTemperatures)
        _draftChunk(
          texts,
          endpoints,
          lang,
          temperature: temp,
          glossary: glossary,
          style: style,
          cot: cot,
          bookContext: bookContext,
          recentTranslations: recentTranslations,
          nextSource: nextSource,
        ),
    ]);
    final ok = <List<String>>[
      for (final d in drafts)
        if (d != null) d,
    ];
    if (ok.isEmpty) return null;
    if (ok.length == 1) return ok.first;
    try {
      final raw = await _requestSynthesis(
        texts: texts,
        drafts: ok,
        endpoints: endpoints,
        lang: lang,
        glossary: glossary,
        style: style,
      );
      final parsed = parseBatched(raw, texts.length);
      if (parsed != null) return parsed;
      AppLog.instance.w('[小说翻译][精译] 合成输出格式异常，取第一稿');
    } on Object {
      AppLog.instance.w('[小说翻译][精译] 合成失败，取第一稿');
    }
    return ok.first;
  }

  /// 单路草稿：请求 + 解析；任一环节失败返回 null（不中断其他草稿）。
  Future<List<String>?> _draftChunk(
    List<String> texts,
    List<AiEndpointConfig> endpoints,
    String lang, {
    required double temperature,
    required List<GlossaryEntry> glossary,
    required TranslationStyle style,
    required bool cot,
    required String? bookContext,
    required List<TranslationContextPair> recentTranslations,
    required String? nextSource,
  }) async {
    try {
      final raw = await _requestBatch(
        texts,
        endpoints,
        lang,
        glossary: glossary,
        style: style,
        cot: cot,
        bookContext: bookContext,
        recentTranslations: recentTranslations,
        nextSource: nextSource,
        temperature: temperature,
      );
      return parseBatched(raw, texts.length);
    } on Object {
      return null;
    }
  }

  /// 精译合成请求：原文 + 各候选草稿，按批量协议回合成结果。
  Future<String> _requestSynthesis({
    required List<String> texts,
    required List<List<String>> drafts,
    required List<AiEndpointConfig> endpoints,
    required String lang,
    required List<GlossaryEntry> glossary,
    required TranslationStyle style,
  }) async {
    final scopedGlossary = GlossaryMatcher.entriesInTexts(glossary, texts);
    final system = PromptBuilder.refineSynthesisSystemPrompt(
      lang: lang,
      paragraphCount: texts.length,
      draftCount: drafts.length,
      glossary: scopedGlossary,
      style: style,
    );
    const labels = <String>['一', '二', '三'];
    final user = StringBuffer()..writeln('【原文】');
    for (var i = 0; i < texts.length; i++) {
      user
        ..writeln('<<<${i + 1}>>>')
        ..writeln(texts[i]);
    }
    for (var d = 0; d < drafts.length; d++) {
      user
        ..writeln()
        ..writeln('【候选译文${labels[d]}】');
      for (var i = 0; i < drafts[d].length; i++) {
        user
          ..writeln('<<<${i + 1}>>>')
          ..writeln(drafts[d][i]);
      }
    }
    return _postChat(endpoints, system, user.toString());
  }

  /// 自动术语提取：仅作品级翻译、设置开启且本批有效段 ≥ 2 时运行。
  /// 失败静默返回 null，绝不打断翻译主流程。
  Future<GlossaryUpsertSummary?> _maybeExtract({
    required List<AiEndpointConfig> endpoints,
    required String lang,
    required String? workId,
    required bool autoExtract,
    required List<String> sources,
    required List<String> translations,
    required List<GlossaryEntry> glossary,
    String? chapterId,
    String? chapterTitle,
    int? chapterIndex,
  }) async {
    final scope = workId?.trim() ?? '';
    if (!autoExtract ||
        scope.isEmpty ||
        sources.length != translations.length) {
      return null;
    }
    final src = <String>[];
    final dst = <String>[];
    for (var i = 0; i < sources.length; i++) {
      if (sources[i].trim().isEmpty || translations[i].trim().isEmpty) continue;
      src.add(sources[i]);
      dst.add(translations[i]);
    }
    if (src.length < 2) return null;
    try {
      final candidates = await _glossaryExtractor.extract(
        endpoints: endpoints,
        lang: lang,
        sources: src,
        translations: dst,
        existing: glossary,
      );
      if (candidates.isEmpty) return null;
      final summary = await _glossary.upsertExtracted(
        scope,
        lang,
        candidates,
        chapterId: chapterId ?? '',
        chapterTitle: chapterTitle ?? '',
        chapterIndex: chapterIndex,
      );
      if (summary.isEmpty) return null;
      AppLog.instance.w('[小说翻译][术语] 本批新增 ${summary.inserted}、'
          '合并 ${summary.merged}、冲突 ${summary.conflicts}');
      return summary;
    } on Object catch (e) {
      AppLog.instance.w('[小说翻译][术语] 自动提取失败，跳过: $e');
      return null;
    }
  }

  Future<List<GlossaryEntry>> _reloadGlossary(
    String? workId,
    String lang, {
    required List<GlossaryEntry> fallback,
  }) async {
    try {
      return await _glossary.effectiveEntries(workId, lang);
    } on Object {
      return fallback;
    }
  }

  /// [from] 之后第一段非空原文（lookahead 断句参考）。
  static String? _nextNonEmpty(List<String> paragraphs, int from) {
    for (var i = from; i < paragraphs.length; i++) {
      final text = paragraphs[i].trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  /// 术语冲突检测：命中告警仅写日志（修正通道后续迭代）。
  void _detectGlossaryConflicts(
    List<GlossaryEntry> glossary,
    List<String> sources,
    List<String> translations,
  ) {
    if (glossary.isEmpty) return;
    try {
      final warnings =
          GlossaryManager.detectConflicts(glossary, sources, translations);
      for (final w in warnings) {
        AppLog.instance.w('[小说翻译][术语冲突] $w');
      }
    } on Object {
      // 检测失败不影响翻译主流程。
    }
  }

  Future<String> _requestBatch(
    List<String> paragraphs,
    List<AiEndpointConfig> endpoints,
    String lang, {
    List<GlossaryEntry> glossary = const <GlossaryEntry>[],
    TranslationStyle style = TranslationStyle.standard,
    bool cot = false,
    String? bookContext,
    List<TranslationContextPair> recentTranslations =
        const <TranslationContextPair>[],
    String? nextSource,
    double temperature = 0.2,
  }) async {
    // 只注入本批原文确实出现的词条，避免长术语表挤占提示词预算。
    final scopedGlossary = GlossaryMatcher.entriesInTexts(glossary, paragraphs);
    final system = PromptBuilder.novelSystemPrompt(
      lang: lang,
      paragraphCount: paragraphs.length,
      glossary: scopedGlossary,
      style: style,
      cot: cot,
      bookContext: bookContext,
      recentTranslations: recentTranslations,
      nextSource: nextSource,
    );
    return _postChat(endpoints, system, encodeBatch(paragraphs),
        temperature: temperature);
  }

  /// 主 → 备 失败路由的 chat/completions 请求（仅连接/超时/429 可切换；
  /// 健康度熔断见路由器），底层异常归一化后上抛。
  Future<String> _postChat(
    List<AiEndpointConfig> endpoints,
    String system,
    String user, {
    double temperature = 0.2,
  }) async {
    try {
      final content = await AiEndpointRouter.execute<String>(
        endpoints,
        (cfg) async {
          final trimmedBase =
              cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
          final resp = await _dio.post<Map<String, dynamic>>(
            '$trimmedBase/chat/completions',
            options: Options(
              headers: <String, dynamic>{
                'Content-Type': 'application/json',
                if (cfg.apiKey.trim().isNotEmpty)
                  'Authorization': 'Bearer ${cfg.apiKey.trim()}',
              },
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 120),
            ),
            data: <String, dynamic>{
              'model': cfg.model.trim().isNotEmpty
                  ? cfg.model.trim()
                  : 'gpt-3.5-turbo',
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{'role': 'system', 'content': system},
                <String, dynamic>{'role': 'user', 'content': user},
              ],
              'temperature': temperature,
            },
          );
          final choices = resp.data?['choices'] as List?;
          if (choices == null || choices.isEmpty) {
            throw const TranslationException('AI 返回内容为空');
          }
          final content =
              (choices.first['message'] as Map?)?['content'] as String?;
          if (content == null || content.trim().isEmpty) {
            throw const TranslationException('AI 返回内容为空');
          }
          return content;
        },
      );
      return content;
    } on Object catch (e) {
      // 网络/超时类底层异常归一化后上抛，原始细节入日志。
      AppLog.instance.w('[小说翻译] 请求失败: $e');
      throw TranslationException.from(e);
    }
  }
}
