/// 漫画页翻译管线（快速路径 + 纠错 + 两阶段兜底）。
///
/// 流程（每页最多 [maxRequestsPerPage] 次逻辑请求）：
/// 1. **快速路径**：一次视觉请求同时 OCR + 翻译，逐条校验译文；
/// 2. **纠错重试**：把未通过条目/解析问题回传给同一端点，要求完整重出；
/// 3. **两阶段兜底**：纯 OCR 出「编号 + 坐标 + 原文」，再用文本模型按
///    `编号|原文` 逐条翻译；缺失/不合格编号做一次定向重试；
/// 4. 任何阶段只要拿到部分可用译文，就带 `partial` 状态返回，不因
///    个别气泡失败而丢掉整页结果。
///
/// 端点切换、限流/5xx 重试由 [AiEndpointRouter] 负责；本类只做流程编排。
library;

import 'dart:typed_data';

import '../../../core/ai/endpoint_router.dart';
import '../../../core/ai/glossary_manager.dart';
import '../../../core/ai/id_translation_protocol.dart';
import '../../../core/ai/prompt_builder.dart';
import '../../../core/ai/translation_exception.dart';
import '../../../core/ai/translation_faithfulness.dart';
import '../../../core/ai/translation_language.dart';
import '../../../core/ai/vision_translation_client.dart';
import '../../../core/comic/comic_translation_manager.dart'
    show ComicTranslationStatus;
import '../../../core/utils/app_log.dart';

/// 单页翻译请求参数。
class ComicTranslationRequest {
  const ComicTranslationRequest({
    required this.endpoints,
    required this.imageBytes,
    required this.mimeType,
    required this.targetLang,
    required this.glossary,
    required this.style,
    required this.contextPairs,
    this.maxTokens,
  });

  final List<AiEndpointConfig> endpoints;
  final Uint8List imageBytes;
  final String mimeType;
  final String targetLang;
  final List<GlossaryEntry> glossary;
  final TranslationStyle style;
  final List<TranslationContextPair> contextPairs;

  /// 视觉请求的 `max_tokens`；null 时用 [ComicTranslationPipeline.visionMaxTokens]。
  final int? maxTokens;
}

/// 单页翻译结果。
class ComicTranslationOutcome {
  const ComicTranslationOutcome({
    required this.segments,
    required this.status,
    required this.requests,
  });

  final List<VisionTextSegment> segments;
  final ComicTranslationStatus status;

  /// 本页实际发起的逻辑请求数（端点切换不重复计数）。
  final int requests;

  int get translatedCount => segments
      .where((s) => s.translation.trim().isNotEmpty)
      .length;
}

/// 漫画页翻译管线。
class ComicTranslationPipeline {
  ComicTranslationPipeline({VisionTranslationClient? client})
      : _client = client ?? VisionTranslationClient();

  final VisionTranslationClient _client;

  /// 每页请求硬上限：快速 1 + 纠错 1 + OCR 1 + 逐条翻译 1 + 定向重试 1。
  static const int maxRequestsPerPage = 5;

  /// 视觉请求输出上限：覆盖常见漫画页的区域数量，又避免无限长输出。
  static const int visionMaxTokens = 4096;

  Future<ComicTranslationOutcome> translatePage(
    ComicTranslationRequest request,
  ) async {
    if (request.endpoints.isEmpty) {
      throw const TranslationException(
          '未配置 AI 接口：请先在 设置 → AI 配置 中填写通用接口或漫画翻译专用接口');
    }
    var requests = 0;
    final lang = request.targetLang;
    final readableLang = TranslationLanguage.readableName(lang);
    final fastPrompt = PromptBuilder.mangaSystemPrompt(
      lang: lang,
      glossary: request.glossary,
      style: request.style,
      contextPairs: request.contextPairs,
    );

    VisionParseOutcome? fast;
    PageFaithfulness? fastCheck;
    try {
      fast = await _vision(
        request,
        fastPrompt,
        expectTranslation: true,
      );
      requests++;
    } on Object catch (e) {
      // 视觉端点是整条链路的基础；连接/认证/限额失败时继续兜底
      // 只会重复烧请求，直接交给上层展示错误。
      AppLog.instance.w('[漫画翻译] 快速路径请求失败: $e');
      rethrow;
    }
    if (fast.ok && fast.segments.isEmpty) {
      return ComicTranslationOutcome(
        segments: const <VisionTextSegment>[],
        status: ComicTranslationStatus.empty,
        requests: requests,
      );
    }
    if (fast.ok) {
      fastCheck = TranslationFaithfulness.validatePage(
        fast.segments,
        lang,
      );
      if (fastCheck.isClean) {
        return ComicTranslationOutcome(
          segments: fast.segments,
          status: ComicTranslationStatus.complete,
          requests: requests,
        );
      }
      AppLog.instance.w('[漫画翻译] 快速路径校验未通过'
          '（${fastCheck.issueCount}/${fastCheck.total}），进入纠错重试');
    }

    // 纠错重试：解析失败时纠正格式/拒答；解析成功时指出具体问题条目。
    VisionParseOutcome? corrected;
    PageFaithfulness? correctedCheck;
    if (requests < maxRequestsPerPage) {
      final note = fast.ok
          ? _visionCorrectionNote(fastCheck!, readableLang)
          : _parseFailureNote(fast.raw, readableLang);
      try {
        corrected = await _vision(
          request,
          fastPrompt,
          expectTranslation: true,
          correctionNote: note,
        );
        requests++;
      } on Object catch (e) {
        AppLog.instance.w('[漫画翻译] 纠错重试失败，继续兜底: $e');
      }
    }
    if (corrected != null && corrected.ok) {
      if (corrected.segments.isEmpty) {
        // 快速路径已解析失败，此时的空数组不足以证明「无文字」，
        // 交给 OCR 复核，避免把拒答/偷懒缓存成空页。
        AppLog.instance.w('[漫画翻译] 纠错返回空数组，交由 OCR 复核');
      } else {
        correctedCheck = TranslationFaithfulness.validatePage(
          corrected.segments,
          lang,
        );
      }
    }
    if (correctedCheck != null) {
      if (correctedCheck.isClean) {
        return ComicTranslationOutcome(
          segments: correctedCheck.accepted,
          status: ComicTranslationStatus.complete,
          requests: requests,
        );
      }
      if (!correctedCheck.needsTwoPhase) {
        return ComicTranslationOutcome(
          segments: correctedCheck.accepted,
          status: ComicTranslationStatus.partial,
          requests: requests,
        );
      }
      AppLog.instance.w('[漫画翻译] 纠错后仍有 '
          '${correctedCheck.issueCount}/${correctedCheck.total} 条未通过，'
          '进入两阶段兜底');
    }

    // 纠错请求本身失败，但快速路径已有大部分可用译文：直接部分展示，
    // 不再为个别瑕疵多烧 OCR + 逐条翻译两次请求。
    if (correctedCheck == null &&
        fastCheck != null &&
        fastCheck.hasAccepted &&
        !fastCheck.needsTwoPhase) {
      return ComicTranslationOutcome(
        segments: fastCheck.accepted,
        status: ComicTranslationStatus.partial,
        requests: requests,
      );
    }

    PageFaithfulness? bestCheck;
    if (correctedCheck != null && correctedCheck.hasAccepted) {
      bestCheck = correctedCheck;
    } else if (fastCheck != null && fastCheck.hasAccepted) {
      bestCheck = fastCheck;
    }
    // 闭包读取当前 requests，回退时计数不会停留在两阶段开始前的旧值。
    ComicTranslationOutcome? bestBeforeTwoPhase() {
      final check = bestCheck;
      if (check == null) return null;
      return ComicTranslationOutcome(
        segments: check.accepted,
        status: check.isClean
            ? ComicTranslationStatus.complete
            : ComicTranslationStatus.partial,
        requests: requests,
      );
    }

    if (requests >= maxRequestsPerPage) {
      return bestBeforeTwoPhase() ??
          _fail('模型返回内容无法解析，且已达本页请求上限');
    }

    // 两阶段第一步：纯 OCR（不出译文，避免视觉模型在长页面上漏译）。
    VisionParseOutcome ocr;
    try {
      ocr = await _vision(
        request,
        PromptBuilder.mangaOcrSystemPrompt(),
        expectTranslation: false,
      );
      requests++;
    } on Object catch (e) {
      AppLog.instance.w('[漫画翻译] OCR 阶段失败: $e');
      return bestBeforeTwoPhase() ??
          _fail(TranslationException.from(e).message);
    }
    if (!ocr.ok) {
      AppLog.instance.w('[漫画翻译] OCR 返回无法解析');
      return bestBeforeTwoPhase() ?? _fail('模型返回内容无法解析');
    }
    final ocrSegments = <VisionTextSegment>[
      for (final segment in ocr.segments)
        if (segment.text.trim().isNotEmpty) segment,
    ];
    if (ocrSegments.isEmpty) {
      return ComicTranslationOutcome(
        segments: const <VisionTextSegment>[],
        status: ComicTranslationStatus.empty,
        requests: requests,
      );
    }
    AppLog.instance.w('[漫画翻译] 两阶段兜底：OCR 识别 ${ocrSegments.length} 条');

    // 两阶段第二步：按编号逐条翻译；编号对位，杜绝漏条错位。
    final sources = <int, String>{
      for (var i = 0; i < ocrSegments.length; i++) i + 1: ocrSegments[i].text,
    };
    final idPrompt = PromptBuilder.mangaSegmentTranslationSystemPrompt(
      lang: lang,
      glossary: request.glossary,
      style: request.style,
      contextPairs: request.contextPairs,
    );
    var translations = <int, String>{};
    if (requests < maxRequestsPerPage) {
      try {
        final parsed = await _translateById(
          request,
          idPrompt,
          sources,
        );
        requests++;
        translations = parsed.translations;
        if (!parsed.isComplete) {
          AppLog.instance.w('[漫画翻译] 逐条翻译不完整：'
              '${IdTranslationProtocol.describeIssues(parsed)}');
        }
      } on Object catch (e) {
        AppLog.instance.w('[漫画翻译] 逐条翻译失败: $e');
      }
    }

    var merged = _merge(ocrSegments, translations);

    // 缺失/不合格编号定向重试（只重发这些编号，成本远低于整页重来）。
    final retryIds = _idsNeedingRetry(ocrSegments, translations, lang);
    if (retryIds.isNotEmpty && requests < maxRequestsPerPage) {
      final retrySources = <int, String>{
        for (final id in retryIds)
          if (sources[id] != null) id: sources[id]!,
      };
      try {
        final retry = await _translateById(
          request,
          idPrompt,
          retrySources,
          correctionNote: '上一次输出中以下编号缺失或不合格：'
              '${retryIds.join(', ')}。请只重新输出这些编号，'
              '格式为「编号|译文」，不要输出其他内容。',
        );
        requests++;
        for (final entry in retry.translations.entries) {
          final source = sources[entry.key];
          if (source == null) continue;
          final issues = TranslationFaithfulness.issuesFor(
            source: source,
            translation: entry.value,
            targetLang: lang,
          );
          if (issues.isEmpty) translations[entry.key] = entry.value;
        }
        merged = _merge(ocrSegments, translations);
      } on Object catch (e) {
        AppLog.instance.w('[漫画翻译] 缺失编号定向重试失败: $e');
      }
    }

    final finalCheck =
        TranslationFaithfulness.validatePage(merged, lang);
    if (finalCheck.accepted.isEmpty) {
      return bestBeforeTwoPhase() ??
          _fail('未能翻译页面文字：所有区域均未通过校验');
    }
    return ComicTranslationOutcome(
      segments: finalCheck.accepted,
      status: finalCheck.isClean
          ? ComicTranslationStatus.complete
          : ComicTranslationStatus.partial,
      requests: requests,
    );
  }

  Future<VisionParseOutcome> _vision(
    ComicTranslationRequest request,
    String prompt, {
    required bool expectTranslation,
    String? correctionNote,
  }) =>
      AiEndpointRouter.execute<VisionParseOutcome>(
        request.endpoints,
        (config) => _client.recognizeImageOutcome(
          config: config,
          imageBytes: request.imageBytes,
          mimeType: request.mimeType,
          systemPrompt: prompt,
          expectTranslation: expectTranslation,
          correctionNote: correctionNote,
          maxTokens: request.maxTokens ?? visionMaxTokens,
        ),
      );

  Future<IdTranslationParse> _translateById(
    ComicTranslationRequest request,
    String prompt,
    Map<int, String> sources, {
    String? correctionNote,
  }) =>
      AiEndpointRouter.execute<IdTranslationParse>(
        request.endpoints,
        (config) => _client.translateSegmentsById(
          config: config,
          systemPrompt: prompt,
          sources: sources,
          correctionNote: correctionNote,
          maxTokens: _idMaxTokens(sources.length),
        ),
      );

  /// 逐条翻译输出上限：按条数估算，避免长页被截断。
  static int _idMaxTokens(int count) =>
      (512 + count * 96).clamp(512, 4096).toInt();

  static List<VisionTextSegment> _merge(
    List<VisionTextSegment> ocrSegments,
    Map<int, String> translations,
  ) =>
      <VisionTextSegment>[
        for (var i = 0; i < ocrSegments.length; i++)
          VisionTextSegment(
            x1: ocrSegments[i].x1,
            y1: ocrSegments[i].y1,
            x2: ocrSegments[i].x2,
            y2: ocrSegments[i].y2,
            text: ocrSegments[i].text,
            translation: translations[i + 1] ?? '',
          ),
      ];

  static List<int> _idsNeedingRetry(
    List<VisionTextSegment> ocrSegments,
    Map<int, String> translations,
    String lang,
  ) {
    final ids = <int>[];
    for (var i = 0; i < ocrSegments.length; i++) {
      final translation = translations[i + 1];
      if (translation == null || translation.trim().isEmpty) {
        ids.add(i + 1);
        continue;
      }
      final issues = TranslationFaithfulness.issuesFor(
        source: ocrSegments[i].text,
        translation: translation,
        targetLang: lang,
      );
      if (issues.isNotEmpty) ids.add(i + 1);
    }
    return ids;
  }

  static String _visionCorrectionNote(
    PageFaithfulness check,
    String readableLang,
  ) {
    final indexes = check.issueIndexes
        .take(8)
        .map((index) => '第 ${index + 1} 条')
        .join('、');
    final problems = <String>{};
    for (final set in check.issues.values) {
      for (final issue in set) {
        problems.add(_issueLabel(issue));
      }
    }
    return '上一次输出存在以下问题：$indexes'
        '（${problems.join('、')}）。请重新检查整张图片并完整输出所有区域，'
        '确保每条 translation 都是$readableLang、非空、不是原文照抄；'
        '只输出 JSON 数组。';
  }

  static String _parseFailureNote(String raw, String readableLang) {
    if (TranslationFaithfulness.looksLikeRefusal(raw)) {
      return '上一次回复包含拒答或解释，没有完成任务。请直接识别图中所有文字区域'
          '并翻译成$readableLang，只输出 JSON 数组，不要输出任何解释。';
    }
    return '上一次回复无法解析为 JSON 数组。请重新识别整张图片，'
        '只输出 JSON 数组（元素含 bbox/text/translation），'
        '不要输出解释、注释或 markdown 代码块。';
  }

  static String _issueLabel(TranslationFaithfulnessIssue issue) =>
      switch (issue) {
        TranslationFaithfulnessIssue.empty => '译文为空',
        TranslationFaithfulnessIssue.refusal => '拒答',
        TranslationFaithfulnessIssue.sourceEcho => '原文照抄',
        TranslationFaithfulnessIssue.wrongTargetScript => '目标语言不符',
        TranslationFaithfulnessIssue.lowCoverage => '疑似漏译/截断',
      };

  static ComicTranslationOutcome _fail(String message) =>
      throw TranslationException(
        message,
        kind: TranslationKind.invalidResponse,
      );
}
