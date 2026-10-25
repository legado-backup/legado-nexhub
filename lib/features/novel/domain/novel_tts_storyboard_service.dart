/// 小说多角色朗读——AI 分镜归因服务（参考 legado_NG 两段式协议）。
///
/// 原则：
/// - **本地先切**：[segmentSpeech] 切出候选段，AI 只负责归因；
/// - **AI 不返回正文**：模型只回 `id → 角色/性别/置信度` 标注，正文由
///   客户端保留，幻觉改不了读出的字；
/// - **置信度门限**：AI 结果 confidence ≥ [minConfidence] 才覆盖本地判定；
/// - **按章缓存**：Hive box `novel_tts_storyboard`，指纹 = 章节文本 +
///   角色卡 + prompt 版本 + 模型名，任何一项变化自动失效；
/// - **优雅降级**：未配置 AI / 请求失败 / 解析失败一律返回 null，朗读
///   继续用本地结果，不阻塞不报错弹窗（AppLog 留诊断日志）；
/// - **自动建卡**：AI 发现的稳定新说话人写入角色卡（source=ai，面板可删）。
///
/// 端点配置复用小说总览（摘要）配置，空则回退通用默认配置。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../../core/ai/ai_chat_client.dart';
import '../../../core/ai/llm_json.dart';
import '../../../core/ai/vision_translation_client.dart'
    show AiEndpointConfig;
import '../../../core/novel/novel_speech_segmenter.dart';
import '../../../core/novel/novel_tts_cast_store.dart';
import '../../../core/utils/app_log.dart';
import '../../../core/novel/novel_http_tts_player.dart' show TtsSentenceUnit;
import 'novel_summary_settings.dart';

/// prompt 协议版本（语义变化时递增，旧缓存自动失效）。
const int kStoryboardPromptVersion = 1;

/// AI 结果被采纳的最低置信度。
const double kStoryboardMinConfidence = 0.6;

/// 单次请求最大句数（超长章节分批）。
const int kStoryboardChunkSize = 100;

/// 单条 AI 归因结果。
@immutable
class StoryboardAttribution {
  const StoryboardAttribution({
    required this.role,
    required this.gender,
    required this.confidence,
  });

  /// 归因角色名（空 = 不指定，仅性别升级时可为空）。
  final String role;
  final String gender;
  final double confidence;
}

/// 一章的归因结果（含 provider 能力）。
class ChapterStoryboard {
  ChapterStoryboard({required this.entries, required this.promptVersion});

  /// unitKey（`段落-句` ）→ 归因。
  final Map<String, StoryboardAttribution> entries;
  final int promptVersion;

  /// 播放器段级 provider：AI 高置信结果覆盖本地角色/性别，其余原样。
  SpeechSegment segmentFor(TtsSentenceUnit unit) {
    final local = unit.segment;
    final ai = entries['${unit.paragraphIndex}-${unit.segIndex}'];
    if (ai == null || ai.confidence < kStoryboardMinConfidence) return local;
    var next = local;
    if (ai.role.isNotEmpty) next = next.copyWith(role: ai.role);
    if (ai.gender != SpeechGender.unknown) {
      next = next.copyWith(gender: ai.gender);
    }
    return next;
  }
}

/// AI 分镜服务。
class NovelTtsStoryboardService {
  NovelTtsStoryboardService({
    NovelTtsCastStore? castStore,
    NovelSummarySettings? settings,
    AiChatClient? chatClient,
    Box<dynamic>? box,
  })  : _castStore = castStore ?? NovelTtsCastStore.instance,
        _settings = settings ?? NovelSummarySettings.instance,
        _chat = chatClient ?? AiChatClient(),
        _boxOverride = box;

  static const String boxName = 'novel_tts_storyboard';

  final NovelTtsCastStore _castStore;
  final NovelSummarySettings _settings;
  final AiChatClient _chat;
  final Box<dynamic>? _boxOverride;
  Box<dynamic>? _box;

  Future<Box<dynamic>> _ensureBox() async {
    final override = _boxOverride;
    if (override != null) return override;
    final box = _box;
    if (box != null) return box;
    if (Hive.isBoxOpen(boxName)) {
      _box = Hive.box(boxName);
    } else {
      _box = await Hive.openBox(boxName);
    }
    return _box!;
  }

  /// 解析可用端点（总览配置自身已含「通用配置」回退；无 baseUrl 返回 null）。
  Future<AiEndpointConfig?> resolveEndpoint() async {
    final cfg = await _settings.getSummaryConfig();
    if (cfg.baseUrl.trim().isEmpty) return null;
    return AiEndpointConfig(
      baseUrl: cfg.baseUrl,
      apiKey: cfg.apiKey,
      model: cfg.model,
    );
  }

  /// 对一章做 AI 归因。
  ///
  /// 命中缓存直接返回；未配置 AI / 失败返回 null（调用方继续本地模式）。
  /// [paragraphs] 为该章正文段落。成功时新角色已写入角色卡。
  Future<ChapterStoryboard?> attributeChapter({
    required String novelId,
    required String chapterId,
    required List<String> paragraphs,
    bool forceRefresh = false,
  }) async {
    try {
      final characters = await _castStore.loadCharacters(novelId);
      final fingerprint = _fingerprint(paragraphs, characters);
      final box = await _ensureBox();
      final cacheKey = '$novelId|$chapterId';
      if (!forceRefresh) {
        final cached = _readCache(box, cacheKey, fingerprint);
        if (cached != null) return cached;
      }

      final endpoint = await resolveEndpoint();
      if (endpoint == null) return null;

      // 候选段：全部段（旁白参与 AI 语境理解但通常不覆盖——仅对白/心声
      // 发给 AI 归因）。
      final units = <(int, int, SpeechSegment, String)>[]; // p, s, seg, para
      final knownGenders = _flattenGenders(characters);
      for (var p = 0; p < paragraphs.length; p++) {
        var s = 0;
        for (final seg in segmentSpeech(paragraphs[p],
            knownGenders: knownGenders)) {
          if (seg.role != narratorRole) {
            units.add((p, s, seg, paragraphs[p]));
          }
          s++;
        }
      }
      if (units.isEmpty) {
        // 全旁白章节：缓存空结果避免每章重复空跑。
        final empty = ChapterStoryboard(
            entries: const {}, promptVersion: kStoryboardPromptVersion);
        await _writeCache(box, cacheKey, fingerprint, empty, const []);
        return empty;
      }

      final entries = <String, StoryboardAttribution>{};
      final newCharacters = <Map<String, dynamic>>[];
      for (var offset = 0; offset < units.length;
          offset += kStoryboardChunkSize) {
        final chunk = units.skip(offset).take(kStoryboardChunkSize).toList();
        final result = await _requestChunk(
            endpoint: endpoint,
            characters: characters,
            chunk: chunk,
            paragraphs: paragraphs);
        if (result == null) return null; // 任一批失败即放弃（下次重试）
        entries.addAll(result.$1);
        newCharacters.addAll(result.$2);
      }

      // 别名归一到规范名（角色卡命中）。
      final canonical = _canonicalIndex(characters);
      final normalized = <String, StoryboardAttribution>{};
      entries.forEach((key, attr) {
        final name = canonical[attr.role.trim()] ?? attr.role.trim();
        normalized[key] = StoryboardAttribution(
            role: name, gender: attr.gender, confidence: attr.confidence);
      });

      final storyboard =
          ChapterStoryboard(entries: normalized, promptVersion: kStoryboardPromptVersion);
      await _writeCache(box, cacheKey, fingerprint, storyboard, newCharacters);

      // 自动建卡（source=ai；已有卡不覆盖手动配置）。
      for (final nc in newCharacters) {
        final name = (nc['name'] as String?)?.trim() ?? '';
        if (name.isEmpty || name.length > 24) continue;
        if (characters.any((c) => c.name == name)) continue;
        final gender = _sanitizeGender(nc['gender'] as String?);
        final aliases = <String>[
          for (final a in (nc['aliases'] as List<dynamic>? ?? const []))
            if (a is String && a.trim().isNotEmpty) a.trim(),
        ];
        await _castStore.upsert(novelId, name,
            aliases: aliases,
            mergeAliases: true,
            gender: gender == SpeechGender.unknown ? null : gender,
            source: NovelCastSource.ai);
      }
      return storyboard;
    } on Object catch (e) {
      AppLog.instance.w('[TTS 分镜] AI 归因失败，使用本地结果: $e');
      return null;
    }
  }

  /// 一批候选段的 AI 请求与解析。
  Future<(Map<String, StoryboardAttribution>, List<Map<String, dynamic>>)?>
      _requestChunk({
    required AiEndpointConfig endpoint,
    required List<NovelCastCharacter> characters,
    required List<(int, int, SpeechSegment, String)> chunk,
    required List<String> paragraphs,
  }) async {
    final unitLines = <String>[];
    for (final (p, s, seg, _) in chunk) {
      final before = _contextBefore(paragraphs, p, seg.text);
      final preview = seg.text.length > 60 ? '${seg.text.substring(0, 60)}…' : seg.text;
      final line = jsonEncode(<String, dynamic>{
        'id': '$p-$s',
        'before': before,
        'text': preview,
      });
      unitLines.add(line);
    }
    final known = characters.isEmpty
        ? '（暂无已知角色）'
        : characters
            .map((c) =>
                '${c.name}（${_genderLabel(c.gender)}）${c.aliases.isEmpty ? '' : '，别名：${c.aliases.join('/')}'}')
            .join('；');

    const system = '你是小说多人朗读的台词归因助手。根据上下文判断每句话的说话人与性别。'
        '只依据输入内容做判断，不创作、不改写正文。输出严格的 JSON 对象，不要输出任何其他文字。';
    final user = '''
已知角色：$known

待标注台词（id / 前文 / 台词）：
${unitLines.join('\n')}

输出 JSON 格式：
{"units":[{"id":"0-0","role":"角色名或空串","gender":"male|female|unknown","confidence":0.0}],"newCharacters":[{"name":"新角色名","gender":"male|female|unknown","aliases":["别名"]}]}

规则：
- role 填已知角色的规范名或其别名原词；无法确定具体角色时填空串。
- gender 仅在上下文足以判断时填写，判不出填 unknown。
- confidence 为 0 到 1 的小数，表示对本次归因的把握。
- newCharacters 只列有稳定姓名/称谓且反复出现的新说话人；路人（大汉、伙计等）与群体称谓不要建。
- 不要输出 JSON 以外的任何内容。''';

    final raw = await _chat.complete(<AiEndpointConfig>[endpoint],
        system: system, user: user, temperature: 0.1);
    final decoded = LlmJson.tryDecodeObject(raw);
    if (decoded == null) return null;

    final validIds = chunk.map((u) => '${u.$1}-${u.$2}').toSet();
    final entries = <String, StoryboardAttribution>{};
    final unitsJson = decoded['units'] as List<dynamic>? ?? const [];
    for (final u in unitsJson) {
      if (u is! Map<String, dynamic>) continue;
      final id = (u['id'] as String?)?.trim() ?? '';
      if (!validIds.contains(id)) continue; // 幻觉 id 丢弃
      final role = _sanitizeRole(u['role'] as String?);
      final gender = _sanitizeGender(u['gender'] as String?);
      final confidence = ((u['confidence'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
      if (role.isEmpty && gender == SpeechGender.unknown) continue;
      entries[id] =
          StoryboardAttribution(role: role, gender: gender, confidence: confidence);
    }
    final newChars = <Map<String, dynamic>>[
      for (final nc in (decoded['newCharacters'] as List<dynamic>? ?? const []))
        if (nc is Map<String, dynamic>) nc,
    ];
    return (entries, newChars);
  }

  // ── 工具 ──

  static String _contextBefore(List<String> paragraphs, int p, String text) {
    final buf = StringBuffer();
    if (p > 0) {
      final prev = paragraphs[p - 1].trim();
      if (prev.isNotEmpty) buf.write(prev.length > 40 ? '…${prev.substring(prev.length - 40)}' : prev);
    }
    final cur = paragraphs[p];
    final idx = cur.indexOf(text);
    if (idx > 0) {
      final lead = cur.substring(0, idx).trim();
      if (lead.isNotEmpty) {
        if (buf.isNotEmpty) buf.write(' ');
        buf.write(lead.length > 40 ? '…${lead.substring(lead.length - 40)}' : lead);
      }
    }
    return buf.toString();
  }

  static Map<String, String> _flattenGenders(List<NovelCastCharacter> chars) {
    final map = <String, String>{};
    for (final c in chars) {
      if (c.gender == SpeechGender.unknown) continue;
      map[c.name] = c.gender;
      for (final a in c.aliases) {
        map.putIfAbsent(a, () => c.gender);
      }
    }
    return map;
  }

  static Map<String, String> _canonicalIndex(List<NovelCastCharacter> chars) {
    final index = <String, String>{};
    for (final c in chars) {
      index.putIfAbsent(c.name, () => c.name);
      for (final a in c.aliases) {
        index.putIfAbsent(a, () => c.name);
      }
    }
    return index;
  }

  static String _sanitizeRole(String? raw) {
    var role = (raw ?? '').trim();
    // 剥引号与控制字符，限长防幻觉长串。
    role = role.replaceAll(RegExp(r'[\p{P}\p{S}]', unicode: true), '').trim();
    if (role.isEmpty) return '';
    // 拒绝明显非人名的输出（如整句台词）。
    if (role.length > 24) return '';
    return role;
  }

  static String _sanitizeGender(String? raw) {
    if (raw == SpeechGender.male || raw == SpeechGender.female) return raw!;
    return SpeechGender.unknown;
  }

  static String _genderLabel(String gender) => switch (gender) {
        SpeechGender.male => '男',
        SpeechGender.female => '女',
        _ => '性别未知',
      };

  /// 缓存指纹：章节文本 + 角色卡 + prompt 版本。
  String _fingerprint(
      List<String> paragraphs, List<NovelCastCharacter> characters) {
    final charsHash = md5.convert(utf8.encode(characters
        .map((c) => '${c.name}|${c.aliases.join(",")}|${c.gender}')
        .join(';')));
    final textHash =
        md5.convert(utf8.encode(paragraphs.join('\u0001')));
    return '$textHash|$charsHash|$kStoryboardPromptVersion';
  }

  ChapterStoryboard? _readCache(
      Box<dynamic> box, String key, String fingerprint) {
    final raw = box.get(key);
    if (raw is! String || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['fingerprint'] != fingerprint) return null;
      final entries = <String, StoryboardAttribution>{
        for (final e in ((json['entries'] as Map<String, dynamic>?)
                ?.entries ??
            const Iterable<MapEntry<String, dynamic>>.empty()))
          e.key: StoryboardAttribution(
            role: (e.value as Map<String, dynamic>)['role'] as String? ?? '',
            gender:
                (e.value as Map<String, dynamic>)['gender'] as String? ??
                    SpeechGender.unknown,
            confidence:
                ((e.value as Map<String, dynamic>)['confidence'] as num?)
                        ?.toDouble() ??
                    0,
          ),
      };
      return ChapterStoryboard(
          entries: entries, promptVersion: kStoryboardPromptVersion);
    } on Object {
      return null;
    }
  }

  Future<void> _writeCache(Box<dynamic> box, String key, String fingerprint,
      ChapterStoryboard storyboard, List<Map<String, dynamic>> newCharacters) async {
    try {
      await box.put(key, jsonEncode(<String, dynamic>{
        'fingerprint': fingerprint,
        'entries': <String, dynamic>{
          for (final e in storyboard.entries.entries)
            e.key: <String, dynamic>{
              'role': e.value.role,
              'gender': e.value.gender,
              'confidence': e.value.confidence,
            },
        },
        'newCharacters': newCharacters,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      }));
    } on Object {
      // 缓存写失败不影响本次结果。
    }
  }
}
