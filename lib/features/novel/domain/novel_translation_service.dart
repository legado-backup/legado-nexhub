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
/// （术语表 + 风格预设 + CoT + 作品语境），术语冲突在响应侧检测入日志；
/// - **块间衔接**：每块请求携带上一块最后 2 段的原文+译文，
/// 缓解代词指代与语气断裂；
/// - **断点续译**：[existing] 传入已完成的部分译文（空串 = 待译），
/// 已完成块直接复用不发请求；[onChunkPersisted] 供调用方逐块落盘检查点；
/// - 译文由调用方经 [NovelTranslationManager] 持久化（导出附带同源）。
library;

import 'package:dio/dio.dart';

import '../../../core/ai/batch_protocol.dart';
import '../../../core/ai/bing_translation_client.dart';
import '../../../core/ai/endpoint_router.dart';
import '../../../core/ai/vision_translation_client.dart' show AiEndpointConfig;
import '../../../core/ai/glossary_manager.dart';
import '../../../core/ai/prompt_builder.dart';
import '../../../core/ai/translation_engine_policy.dart';
import '../../../core/ai/translation_exception.dart';
import '../../../core/ai/translation_feature_flags.dart';
import '../../../core/ai/translation_language.dart';
import '../../../core/ai/translation_options_store.dart';
import '../../../core/ai/vision_translation_client.dart' show TranslationContextPair;
import '../../../core/utils/app_log.dart';
import '../../../../core/novel/novel_translation_manager.dart';
import 'novel_summary_settings.dart';
import 'novel_summary_service.dart' show NovelSummaryConfig;

/// 段落翻译服务。
class NovelTranslationService {
  NovelTranslationService({
    Dio? dio,
    NovelSummarySettings? settings,
    String? targetLanguage,
    GlossaryManager? glossary,
    TranslationOptionsStore? options,
    BingTranslationClient? bingClient,
  })  : _dio = dio ?? Dio(),
        _settings = settings ?? NovelSummarySettings.instance,
        _targetLanguage = targetLanguage,
        _glossary = glossary ?? GlossaryManager(),
        _options = options ?? TranslationOptionsStore(),
        _bing = bingClient ?? BingTranslationClient();

  final Dio _dio;
  final NovelSummarySettings _settings;
  final GlossaryManager _glossary;
  final TranslationOptionsStore _options;
  final BingTranslationClient _bing;

  /// 翻译目标语言（提示词用，默认中文）；null 时运行时读翻译配置页设置。
  final String? _targetLanguage;

  /// 单次请求的段落数上限：超过直接分块，避免必然截断的超大请求。
  static const int _kOneShotMaxParagraphs = 40;

  /// 块间衔接段数：每块请求携带上一块最后 2 段的原文+译文。
  static const int _kChunkContextPairs = 2;

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
  /// 译文快照，供调用方落盘检查点；[bookContext] 为 全书概述注入。
  Future<List<String>> translateParagraphs(
    List<String> paragraphs, {
    int? batchSize,
    void Function(int done, int total)? onProgress,
    String? workId,
    List<String> existing = const <String>[],
    void Function(List<String> translatedSoFar)? onChunkPersisted,
    String? bookContext,
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
    try {
      glossary = await _glossary.effectiveEntries(workId, lang);
      style = await _options.effectiveStyle(workId);
      cot = await _options.getCotEnabled();
    } on Object {
      AppLog.instance.w('[小说翻译] 术语表/风格读取失败，按默认注入');
    }

    // 已完成的段落（existing 非空段）直接复用。
    final result = List<String>.generate(
      paragraphs.length,
      (i) => (i < existing.length ? existing[i] : '') ?? '',
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
          bookContext: bookContext,
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
  /// 只对未完成段落发请求。
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
    required String? bookContext,
    void Function(int done, int total)? onProgress,
    void Function(List<String> translatedSoFar)? onChunkPersisted,
  }) async {
    // 1) 整章一次批量（最省 token）；超大章或已有断点直接跳过，
    //    必然截断的请求不值得先付一次 token/延迟；失败/解析不齐 → 分块回退。
    final bool tryOneShot = allowOneShot &&
        paragraphs.length <= _kOneShotMaxParagraphs &&
        !hasPartial &&
        !_allDone(paragraphs, result);
    if (tryOneShot) {
      try {
        final oneShot = await _requestBatch(
          paragraphs,
          endpoints,
          lang,
          glossary: glossary,
          style: style,
          cot: cot,
          bookContext: bookContext,
        );
        final parsed = parseBatched(oneShot, paragraphs.length);
        if (parsed != null) {
          _detectGlossaryConflicts(glossary, paragraphs, parsed);
          for (var i = 0; i < result.length; i++) {
            if (!_isDone(paragraphs, result, i)) result[i] = parsed[i];
          }
          onProgress?.call(paragraphs.length, paragraphs.length);
          onChunkPersisted?.call(List<String>.of(result));
          return;
        }
      } on Object catch (e) {
        AppLog.instance.w('[小说翻译] 整章批量失败，转入分块回退: $e');
      }
    }

    // 2) 分块翻译（每块 chunkSize 段，块内仍走批量协议）。
    // 整块已完成直接跳过，不重复请求；携带上一块最后 2 段原文+译文衔接。
    List<TranslationContextPair> chunkContext = const <TranslationContextPair>[];
    for (var start = 0; start < paragraphs.length; start += chunkSize) {
      final end = (start + chunkSize).clamp(0, paragraphs.length);
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
          final raw = await _requestBatch(
            pendingTexts,
            endpoints,
            lang,
            glossary: glossary,
            style: style,
            cot: cot,
            bookContext: bookContext,
            priorContext: chunkContext,
          );
          final parsed = parseBatched(raw, pendingTexts.length) ??
              (throw const TranslationException('翻译返回格式异常'));
          _detectGlossaryConflicts(glossary, pendingTexts, parsed);
          for (var i = 0; i < pendingTexts.length; i++) {
            result[pendingIndexes[i]] = parsed[i];
          }
          chunkContext = <TranslationContextPair>[
            for (var i = (pendingTexts.length - _kChunkContextPairs)
                .clamp(0, pendingTexts.length);
                i < pendingTexts.length;
                i++)
              (source: pendingTexts[i], translation: parsed[i]),
          ];
        }
      } else {
        // 已完成块同样维护上下文，保证下一块衔接自然。
        final realIndexes = <int>[
          for (var i = start; i < end; i++)
            if (paragraphs[i].trim().isNotEmpty) i,
        ];
        chunkContext = <TranslationContextPair>[
          for (var i = (realIndexes.length - _kChunkContextPairs)
              .clamp(0, realIndexes.length);
              i < realIndexes.length;
              i++)
            (
              source: paragraphs[realIndexes[i]],
              translation: result[realIndexes[i]],
            ),
        ];
      }
      onProgress?.call(_doneCount(paragraphs, result), paragraphs.length);
      onChunkPersisted?.call(List<String>.of(result));
    }
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
    List<TranslationContextPair> priorContext = const <TranslationContextPair>[],
  }) async {
    final system = PromptBuilder.novelSystemPrompt(
      lang: lang,
      paragraphCount: paragraphs.length,
      glossary: glossary,
      style: style,
      cot: cot,
      bookContext: bookContext,
    );
    try {
      // 主 → 备 失败路由（仅连接/超时/429 可切换；健康度熔断见路由器）。
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
                // 上一块末尾若干段的原文+译文，作为衔接语境。
                for (final h in priorContext) ...<Map<String, dynamic>>[
                  <String, dynamic>{
                    'role': 'user',
                    'content': encodeBatch(<String>[h.source]),
                  },
                  <String, dynamic>{
                    'role': 'assistant',
                    'content': h.translation
                  },
                ],
                <String, dynamic>{
                  'role': 'user',
                  'content': encodeBatch(paragraphs)
                },
              ],
              'temperature': 0.2,
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
