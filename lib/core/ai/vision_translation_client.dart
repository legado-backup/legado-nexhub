/// AI 视觉识别 + 翻译统一客户端（漫画页翻译 / 视频画面 OCR 共用）。
///
/// 走 OpenAI 兼容 `chat/completions` 接口（与小说翻译同族协议）：
/// - **视觉请求**：图片以 `data:` base64 随消息发送，模型同时完成
/// 文字识别（OCR）与翻译，返回带区域坐标的 JSON；
/// - **文本请求**：批量协议 `<<<N>>>` 序号分隔（对齐小说段落翻译），
/// 一次请求翻译多条短句（视频字幕逐句场景）。
///
/// 接口配置（baseUrl/apiKey/model）由调用方传入（各功能读取自己的
/// 功能级配置并回落通用配置），本文件不依赖任何 feature 层代码。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'batch_protocol.dart';
import 'id_translation_protocol.dart';
import 'llm_json.dart';
import 'prompt_builder.dart';
import 'translation_exception.dart';

/// 一对「原文→译文」语境（上下文注入的对话历史单元）。
typedef TranslationContextPair = ({String source, String translation});

/// 一次视觉解析结果。
///
/// [ok] 区分「模型正常返回空数组」与「返回内容无法解析」：
/// 前者是可以缓存的空页，后者需要纠错重试或两阶段兜底。
class VisionParseOutcome {
  const VisionParseOutcome({
    required this.ok,
    required this.segments,
    required this.raw,
  });

  final bool ok;
  final List<VisionTextSegment> segments;

  /// 模型原始输出（解析失败时用于识别拒答/截断）。
  final String raw;

  bool get isEmpty => ok && segments.isEmpty;
}

/// 一段识别并翻译后的文字区域（坐标为相对图片宽高的千分比 0–1000）。
class VisionTextSegment {
  /// 归一化千分比坐标（左上原点）：x1/y1/x2/y2；无坐标（纯文本 OCR）时为 null。
  final int? x1;
  final int? y1;
  final int? x2;
  final int? y2;

  /// 识别出的原文。
  final String text;

  /// 翻译后的文本。
  final String translation;

  const VisionTextSegment({
    this.x1,
    this.y1,
    this.x2,
    this.y2,
    required this.text,
    required this.translation,
  });

  bool get hasBbox =>
      x1 != null && y1 != null && x2 != null && y2 != null && x2! > x1! && y2! > y1!;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (x1 != null) 'x1': x1,
        if (y1 != null) 'y1': y1,
        if (x2 != null) 'x2': x2,
        if (y2 != null) 'y2': y2,
        'text': text,
        'translation': translation,
      };

  factory VisionTextSegment.fromJson(Map<String, dynamic> json) =>
      VisionTextSegment(
        x1: (json['x1'] as num?)?.toInt(),
        y1: (json['y1'] as num?)?.toInt(),
        x2: (json['x2'] as num?)?.toInt(),
        y2: (json['y2'] as num?)?.toInt(),
        text: json['text'] as String? ?? '',
        translation: json['translation'] as String? ?? '',
      );
}

/// AI 接口三元组（与小说域 NovelSummaryConfig 同构，独立定义避免 core→feature 依赖）。
class AiEndpointConfig {
  final String baseUrl;
  final String apiKey;
  final String model;

  const AiEndpointConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  bool get isConfigured => baseUrl.trim().isNotEmpty;
}

/// 视觉识别 + 翻译客户端。
class VisionTranslationClient {
  VisionTranslationClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// 漫画页 OCR+翻译提示词（基础段；术语/风格等公共段由
  /// [PromptBuilder.mangaSystemPrompt] 追加）。
  static String mangaBasePrompt(String targetLang) =>
      '你是专业的漫画翻译引擎。用户会给出一张漫画页面图片。'
      '任务：先识别图中所有带文字的区域，再把每个区域的文字翻译成$targetLang。'
      '需要处理对话气泡、旁白框、思考框、拟声词/音效、标注与小字。'
      '规则：'
      '1. 逐区域独立处理，不要合并、拆分、遗漏或重复区域；'
      '2. 译文自然、符合角色语气与场景，保留称呼、语气词与强调；'
      '拟声词译成$targetLang中自然的拟声表达；'
      '3. text 保留图中原文（原语言原样），translation 必须是$targetLang，'
      '不能照抄原文，不能为空；'
      '4. 忽略签名、水印、页码、出版社标识等非正文文字；'
      '5. 坐标是该区域外接矩形在整张图片宽高上的千分比'
      '（0-1000，左上角为原点，x 向右 y 向下），按阅读顺序输出；'
      '6. 只输出一个 JSON 数组，不要输出解释、注释或 markdown 代码块围栏；'
      '7. 若图中没有需要翻译的文字，输出 []。'
      '数组元素格式：'
      '{"bbox":[x1,y1,x2,y2],"text":"原文","translation":"译文"}。';

  /// 漫画页纯 OCR 提示词（两阶段兜底的第一阶段）：只识别不翻译。
  static String mangaOcrBasePrompt() =>
      '你是专业的漫画文字识别引擎。用户会给出一张漫画页面图片。'
      '只做文字识别，不要翻译。识别图中所有带文字的区域'
      '（对话气泡、旁白框、思考框、拟声词、标注与小字）。'
      '规则：'
      '1. 逐区域独立输出，不要合并、拆分、遗漏或重复区域；'
      '2. text 保留图中原文（原语言原样），不要改写或翻译；'
      '3. 忽略签名、水印、页码、出版社标识等非正文文字；'
      '4. 坐标是该区域外接矩形在整张图片宽高上的千分比'
      '（0-1000，左上角为原点），按阅读顺序输出；'
      '5. 只输出一个 JSON 数组，不要输出解释、注释或 markdown 代码块围栏；'
      '6. 若图中没有文字，输出 []。'
      '数组元素格式：{"bbox":[x1,y1,x2,y2],"text":"原文"}。';

  /// 旧入口（兼容）：基础段别名。
  static String mangaSystemPrompt(String targetLang) =>
      mangaBasePrompt(targetLang);

  /// 视频帧 OCR+翻译提示词（基础段；公共段由 [PromptBuilder] 追加）：
  /// 识别画面中的字幕/台词文字并翻译，不需要坐标，输出逐行原文+译文。
  static String videoOcrBasePrompt(String targetLang) =>
      '你是专业的视频字幕识别引擎。用户会给出一个视频画面帧。'
      '请识别画面中的台词/字幕文字（忽略台标、水印、进度条、按钮等界面元素），'
      '把识别结果翻译成$targetLang。'
      '只输出一个 JSON 数组，不要输出任何解释或 markdown 代码块围栏。'
      '数组每个元素格式：{"text":"原文","translation":"译文"}，'
      '按阅读顺序排列。若画面中没有台词文字，输出 []。';

  /// 旧入口（兼容）：基础段别名。
  static String videoOcrSystemPrompt(String targetLang) =>
      videoOcrBasePrompt(targetLang);

  /// 单次视觉请求：识别并翻译图片中的文字（兼容入口，解析失败返回空）。
  ///
  /// [mimeType] 目前支持 image/jpeg / image/png。
  Future<List<VisionTextSegment>> recognizeImage({
    required AiEndpointConfig config,
    required Uint8List imageBytes,
    required String mimeType,
    required String systemPrompt,
    int maxSide = 1600,
  }) async {
    final outcome = await recognizeImageOutcome(
      config: config,
      imageBytes: imageBytes,
      mimeType: mimeType,
      systemPrompt: systemPrompt,
      maxSide: maxSide,
    );
    return outcome.segments;
  }

  /// 单次视觉请求，返回带「是否解析成功」信号的结果。
  ///
  /// [expectTranslation] 为 false 时走纯 OCR 解析（只读 `text`），
  /// 不会把原文回填到 `translation`；[correctionNote] 会作为图片后的
  /// 文本指令追加，用于纠错重试（例如要求只输出 JSON 数组）。
  Future<VisionParseOutcome> recognizeImageOutcome({
    required AiEndpointConfig config,
    required Uint8List imageBytes,
    required String mimeType,
    required String systemPrompt,
    bool expectTranslation = true,
    String? correctionNote,
    int? maxTokens,
    double temperature = 0.2,
    Duration receiveTimeout = const Duration(seconds: 180),
    int maxSide = 1600,
  }) async {
    final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final note = correctionNote?.trim();
    final resp = await _dio.post<Map<String, dynamic>>(
      '$base/chat/completions',
      options: Options(
        headers: _headers(config),
        sendTimeout: const Duration(seconds: 60),
        receiveTimeout: receiveTimeout,
      ),
      data: <String, dynamic>{
        'model': _model(config),
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': systemPrompt},
          <String, dynamic>{
            'role': 'user',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'image_url',
                'image_url': <String, dynamic>{
                  'url':
                      'data:$mimeType;base64,${base64Encode(imageBytes)}',
                },
              },
              if (note != null && note.isNotEmpty)
                <String, dynamic>{'type': 'text', 'text': note},
            ],
          },
        ],
        'temperature': temperature,
        if (maxTokens != null) 'max_tokens': maxTokens,
      },
    );
    final content = _extractContent(resp.data);
    if (content == null || content.trim().isEmpty) {
      throw const TranslationException(
        'AI 返回内容为空',
        kind: TranslationKind.invalidResponse,
      );
    }
    return parseSegmentsOutcome(
      content,
      expectTranslation: expectTranslation,
    );
  }

  /// 纯文本逐条翻译：输入「编号 → 原文」，按编号解析译文。
  ///
  /// 两阶段漫画翻译的第二阶段使用；[correctionNote] 用于缺失编号的
  /// 定向重试（只重发缺失条目）。解析结果不抛异常，由调用方按
  /// [IdTranslationParse.missingIds] 决定部分接受或重试。
  Future<IdTranslationParse> translateSegmentsById({
    required AiEndpointConfig config,
    required String systemPrompt,
    required Map<int, String> sources,
    String? correctionNote,
    double temperature = 0.2,
    int? maxTokens,
    Duration receiveTimeout = const Duration(seconds: 120),
  }) async {
    final ids = sources.keys.toList()..sort();
    if (ids.isEmpty) {
      return const IdTranslationParse(
        translations: <int, String>{},
        missingIds: <int>[],
        duplicateIds: <int>[],
        unknownIds: <int>[],
        lineCount: 0,
      );
    }
    final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final body = StringBuffer(IdTranslationProtocol.encodeMap(sources));
    final note = correctionNote?.trim();
    if (note != null && note.isNotEmpty) {
      body
        ..writeln()
        ..writeln()
        ..write(note);
    }
    final resp = await _dio.post<Map<String, dynamic>>(
      '$base/chat/completions',
      options: Options(
        headers: _headers(config),
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: receiveTimeout,
      ),
      data: <String, dynamic>{
        'model': _model(config),
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': systemPrompt},
          <String, dynamic>{'role': 'user', 'content': body.toString()},
        ],
        'temperature': temperature,
        if (maxTokens != null) 'max_tokens': maxTokens,
      },
    );
    final content = _extractContent(resp.data);
    if (content == null || content.trim().isEmpty) {
      throw const TranslationException(
        'AI 返回内容为空',
        kind: TranslationKind.invalidResponse,
      );
    }
    return IdTranslationProtocol.parse(content, expectedIds: ids);
  }

  Map<String, dynamic> _headers(AiEndpointConfig config) =>
      <String, dynamic>{
        'Content-Type': 'application/json',
        if (config.apiKey.trim().isNotEmpty)
          'Authorization': 'Bearer ${config.apiKey.trim()}',
      };

  static String _model(AiEndpointConfig config) =>
      config.model.trim().isNotEmpty ? config.model.trim() : 'gpt-4o-mini';

  /// 批量翻译短句（视频字幕场景）：一次请求翻译多条，返回与输入等长的译文。
  ///
  /// 复用 [BatchProtocol]（`<<<N>>>` 编号分隔，与小说翻译同一份实现）；
  /// 解析失败/条数不齐时抛异常，由调用方决定回退策略（逐条重试等）。
  ///
  /// - [history]（上下文注入）：会话内最近若干句 {原文, 译文}，按时间
  /// 升序注入为对话历史 messages（预算淘汰由调用方负责）；
  /// - [lightweight]（轻量格式）：要求纯文本逐行输出（无编号）省 token，
  /// 解析靠顺序对位（[BatchProtocol.decodeLoose]），失败回退编号协议；
  /// - [systemPrompt]：调用方经 [PromptBuilder] 组装好的完整提示词，
  /// 传入时覆盖内置默认（术语/风格注入统一走该通道）。
  Future<List<String>> translateBatch({
    required AiEndpointConfig config,
    required String targetLang,
    required List<String> texts,
    List<TranslationContextPair> history = const <TranslationContextPair>[],
    bool lightweight = false,
    String? systemPrompt,
  }) async {
    if (texts.isEmpty) return const <String>[];
    final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'system',
        'content': systemPrompt ??
            PromptBuilder.subtitleSystemPrompt(lang: targetLang),
      },
      // 前文语境作为对话历史注入（升序，最新一句紧邻本次请求）。
      for (final h in history) ...<Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': BatchProtocol.encode(<String>[h.source]),
        },
        <String, dynamic>{'role': 'assistant', 'content': h.translation},
      ],
      <String, dynamic>{'role': 'user', 'content': BatchProtocol.encode(texts)},
    ];
    final resp = await _dio.post<Map<String, dynamic>>(
      '$base/chat/completions',
      options: Options(
        headers: <String, dynamic>{
          'Content-Type': 'application/json',
          if (config.apiKey.trim().isNotEmpty)
            'Authorization': 'Bearer ${config.apiKey.trim()}',
        },
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 120),
      ),
      data: <String, dynamic>{
        'model': config.model.trim().isNotEmpty
            ? config.model.trim()
            : 'gpt-4o-mini',
        'messages': messages,
        'temperature': 0.2,
      },
    );
    final content = _extractContent(resp.data);
    // 轻量格式优先逐行对位，失败回退编号协议；编号格式反之。
    final parsed = lightweight
        ? (BatchProtocol.decodeLoose(content ?? '', texts.length) ??
            BatchProtocol.decode(content ?? '', texts.length))
        : (BatchProtocol.decode(content ?? '', texts.length) ??
            BatchProtocol.decodeLoose(content ?? '', texts.length));
    if (parsed == null) throw Exception('翻译返回格式异常');
    return parsed;
  }

  static String? _extractContent(Map<String, dynamic>? data) {
    final choices = data?['choices'] as List?;
    if (choices == null || choices.isEmpty) return null;
    return (choices.first['message'] as Map?)?['content'] as String?;
  }

  /// 宽容解析模型返回的区域 JSON（兼容入口；解析失败返回空列表）。
  static List<VisionTextSegment> parseSegmentsJson(String raw) =>
      parseSegmentsOutcome(raw).segments;

  /// 宽容解析模型返回的区域 JSON，并保留「是否解析成功」信号。
  ///
  /// 剥掉 markdown 围栏 / 前后杂文后解析最外层数组；兼容
  /// `{"segments":[...]}` 包裹、bbox 数组/对象、平铺坐标、0–1 归一化
  /// 坐标。译文缺失时保留空串（不回填原文），让忠实度校验能识别漏译。
  static VisionParseOutcome parseSegmentsOutcome(
    String raw, {
    bool expectTranslation = true,
  }) {
    final text = raw.trim();
    if (text.isEmpty) {
      return VisionParseOutcome(
        ok: false,
        segments: const <VisionTextSegment>[],
        raw: raw,
      );
    }
    final dynamic decoded = LlmJson.tryDecode(text);
    List<dynamic>? list;
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map) {
      for (final key in const <String>[
        'segments',
        'results',
        'items',
        'regions',
        'data',
      ]) {
        final value = decoded[key];
        if (value is List) {
          list = value;
          break;
        }
      }
    }
    if (list == null) {
      return VisionParseOutcome(
        ok: false,
        segments: const <VisionTextSegment>[],
        raw: raw,
      );
    }

    final result = <VisionTextSegment>[];
    for (final dynamic item in list) {
      if (item is! Map) continue;
      final map =
          item is Map<String, dynamic> ? item : item.cast<String, dynamic>();
      final coords = _readBbox(map['bbox'] ?? map['box']);
      final int? x1 = coords.$1 ??
          _toInt(map['x1'] ?? map['left'] ?? map['x']);
      final int? y1 = coords.$2 ??
          _toInt(map['y1'] ?? map['top'] ?? map['y']);
      final int? x2 = coords.$3 ??
          _toInt(map['x2'] ?? map['right']);
      final int? y2 = coords.$4 ??
          _toInt(map['y2'] ?? map['bottom']);
      final source = _stringField(map, const <String>[
        'text',
        'original',
        'source',
      ]);
      final translation = expectTranslation
          ? _stringField(map, const <String>['translation', 'translated'])
          : '';
      if (source.isEmpty && translation.isEmpty) continue;
      result.add(VisionTextSegment(
        x1: x1,
        y1: y1,
        x2: x2,
        y2: y2,
        text: source,
        translation: translation,
      ));
    }
    // 数组非空但没有任何有效区域：按解析失败处理，避免误缓存为空页。
    if (list.isNotEmpty && result.isEmpty) {
      return VisionParseOutcome(
        ok: false,
        segments: const <VisionTextSegment>[],
        raw: raw,
      );
    }
    return VisionParseOutcome(ok: true, segments: result, raw: raw);
  }

  static int? _toInt(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static String _stringField(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is num) return value.toString();
    }
    return '';
  }

  /// 读取 bbox：支持 `[x1,y1,x2,y2]`、对象和平铺字段；0–1 归一化
  /// 坐标自动换算为千分比（模型偶尔会忽略提示词的单位要求）。
  static (int?, int?, int?, int?) _readBbox(dynamic raw) {
    double? a;
    double? b;
    double? c;
    double? d;
    if (raw is List && raw.length >= 4) {
      a = _toDouble(raw[0]);
      b = _toDouble(raw[1]);
      c = _toDouble(raw[2]);
      d = _toDouble(raw[3]);
    } else if (raw is Map) {
      a = _toDouble(raw['x1'] ?? raw['left'] ?? raw['x']);
      b = _toDouble(raw['y1'] ?? raw['top'] ?? raw['y']);
      c = _toDouble(raw['x2'] ?? raw['right']);
      d = _toDouble(raw['y2'] ?? raw['bottom']);
    }
    if (a == null || b == null || c == null || d == null) {
      return (null, null, null, null);
    }
    final values = <double>[a, b, c, d];
    final maxValue = values.reduce((x, y) => x > y ? x : y);
    final normalized = maxValue <= 1.5;
    int scale(double v) => normalized ? (v * 1000).round() : v.round();
    return (scale(a), scale(b), scale(c), scale(d));
  }

  static double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }
}
