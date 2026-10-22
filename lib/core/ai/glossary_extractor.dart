/// 批次术语自动提取（翻译后闭环）。
///
/// 输入同一批「原文 + 实际译文」，让模型抽取人名/地名/组织/称谓/固有名
/// 等需要跨章节保持一致的词条；输出只作为候选，最终由
/// [GlossaryManager.upsertExtracted] 决定插入、合并别名或记录冲突。
///
/// 成本与稳定性约束：
/// - 每批一次小请求（temperature 0.1，输出上限 20 条），失败静默跳过；
/// - 只注入本批原文确实出现的已有术语，避免长术语表挤占提示词；
/// - `translation` 必须是本批译文中的实际译法，不允许模型「顺便优化」，
///   否则冲突记录会失真。
library;

import 'package:dio/dio.dart';

import 'ai_chat_client.dart';
import 'glossary_manager.dart';
import 'glossary_matcher.dart';
import 'vision_translation_client.dart' show AiEndpointConfig;
import '../utils/app_log.dart';

class GlossaryExtractor {
  GlossaryExtractor({Dio? dio, AiChatClient? client})
      : _client = client ?? AiChatClient(dio: dio);

  final AiChatClient _client;

  /// 单批最多收录条数（控制输出长度与术语表噪声）。
  static const int maxBatchEntries = 20;

  static const int _maxTermChars = 40;
  static const int _maxTranslationChars = 80;
  static const int _maxNoteChars = 120;

  static const Set<String> _types = <String>{
    GlossaryEntry.typeTerm,
    'person',
    'place',
    'org',
    'appellation',
    'honorific',
    'speech',
    'fixed_expression',
  };

  static const Map<String, String> _typeAliases = <String, String>{
    '人名': 'person',
    '人物': 'person',
    'name': 'person',
    '地名': 'place',
    '地点': 'place',
    '组织': 'org',
    '机构': 'org',
    'organization': 'org',
    '称谓': 'appellation',
    '称号': 'appellation',
    '敬称': 'honorific',
    '敬语': 'honorific',
    '口癖': 'speech',
    '口头禅': 'speech',
    '固定表达': 'fixed_expression',
    '惯用语': 'fixed_expression',
    '术语': 'term',
  };

  /// 提取本批术语；任何失败都返回空列表（不影响翻译主流程）。
  Future<List<GlossaryEntry>> extract({
    required List<AiEndpointConfig> endpoints,
    required String lang,
    required List<String> sources,
    required List<String> translations,
    List<GlossaryEntry> existing = const <GlossaryEntry>[],
  }) async {
    if (endpoints.isEmpty ||
        sources.length < 2 ||
        sources.length != translations.length) {
      return const <GlossaryEntry>[];
    }
    final scoped = GlossaryMatcher.entriesInTexts(existing, sources);
    try {
      final decoded = await _client.completeJson(
        endpoints,
        system: buildSystemPrompt(lang),
        user: buildUserPrompt(
          lang: lang,
          sources: sources,
          translations: translations,
          existing: scoped,
        ),
        temperature: 0.1,
        maxTokens: 1500,
      );
      return parseCandidates(decoded);
    } on Object catch (e) {
      AppLog.instance.w('[术语提取] 失败，跳过本批: $e');
      return const <GlossaryEntry>[];
    }
  }

  static String buildSystemPrompt(String lang) => '''
你是专业的文学术语整理助手。用户会给出同一批小说的「编号原文段落」与「对应译文」，请从原文中抽取需要跨章节保持一致的术语，并给出它们在本次译文中的实际译法（目标语言：$lang）。

抽取范围：
- 人名、地名、组织/家族/门派/势力名；
- 称号、称谓、敬称、昵称、口癖；
- 技能、招式、道具、功法、专有概念等固定表达。

规则：
1. term 必须是原文中逐字出现的词（日文/英文等保持原样），不要改写或翻译。
2. translation 必须是本次译文中实际出现的译法，逐字摘取；不要自行发明更优译名。
3. 若已有术语表中的词条在本批原文出现，而本批译文用了不同译法，仍按实际译文输出该词条，系统会记录冲突。
4. 忽略普通名词、代词、形容词、一次性描述，以及仅出现一次且不影响后续理解的词。
5. 最多输出 $maxBatchEntries 条，优先反复出现、对情节重要的词。
6. 只输出 JSON 数组，不要输出解释或 markdown 围栏。每项格式：
   {"term":"原文词","translation":"本次译文","type":"person|place|org|appellation|honorific|speech|fixed_expression|term","aliases":["可选别名"],"note":"可选简短说明"}
   若没有可抽取的术语，输出 []。''';

  static String buildUserPrompt({
    required String lang,
    required List<String> sources,
    required List<String> translations,
    required List<GlossaryEntry> existing,
  }) {
    final buf = StringBuffer('目标语言：$lang\n');
    if (existing.isNotEmpty) {
      buf.writeln('已有术语（本批原文出现；若译文与既定译名不同，请按实际译文输出）：');
      for (final e in existing) {
        buf.writeln('- ${e.term}→${e.preferred}'
            '${e.aliases.isEmpty ? '' : '（别名：${e.aliases.take(3).join('、')}）'}');
      }
    }
    buf.writeln('原文与译文：');
    for (var i = 0; i < sources.length; i++) {
      buf
        ..writeln('<<<${i + 1}>>>')
        ..writeln('原文：${sources[i].trim()}')
        ..writeln('译文：${translations[i].trim()}');
    }
    return buf.toString();
  }

  /// 解析模型返回（数组，或含 terms/glossary/entries 的对象）。
  static List<GlossaryEntry> parseCandidates(dynamic decoded) {
    final list = _asCandidateList(decoded);
    if (list == null) return const <GlossaryEntry>[];
    final result = <GlossaryEntry>[];
    final seen = <String>{};
    for (final item in list) {
      if (item is! Map) continue;
      final map = item;
      final term = _readString(map, const <String>[
        'term',
        'source',
        'original',
        '原文',
        '术语',
      ]);
      final translation = _readString(map, const <String>[
        'translation',
        'target',
        'translated',
        '译文',
        '译名',
      ]);
      if (term == null || translation == null) continue;
      if (term.length > _maxTermChars ||
          translation.length > _maxTranslationChars ||
          !seen.add(term)) {
        continue;
      }
      final aliases = _readStringList(
        map['aliases'] ?? map['alias'] ?? map['别名'],
      );
      final note = _readString(map, const <String>['note', '备注']) ?? '';
      result.add(GlossaryEntry(
        id: '',
        term: term,
        preferred: translation,
        aliases: aliases,
        note: note.length > _maxNoteChars
            ? note.substring(0, _maxNoteChars)
            : note,
        type: normalizeType(map['type'] ?? map['类型']),
      ));
      if (result.length >= maxBatchEntries) break;
    }
    return result;
  }

  static List<dynamic>? _asCandidateList(dynamic decoded) {
    if (decoded is List) return decoded;
    if (decoded is Map) {
      for (final key in const <String>[
        'terms',
        'glossary',
        'entries',
        'items',
        'data',
      ]) {
        final value = decoded[key];
        if (value is List) return value;
      }
    }
    return null;
  }

  static String? _readString(Map<dynamic, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String) {
        final text = value.trim();
        if (text.isNotEmpty) return text;
      }
    }
    return null;
  }

  static List<String> _readStringList(dynamic raw) {
    final out = <String>[];
    if (raw is List) {
      for (final value in raw) {
        if (value is String && value.trim().isNotEmpty) {
          out.add(value.trim());
        }
      }
    } else if (raw is String && raw.trim().isNotEmpty) {
      out.addAll(
        raw
            .split(RegExp(r'[、,，;；/]'))
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty),
      );
    }
    return out.take(5).toList();
  }

  /// 类型归一化：兼容中文类型名与未知值（回落到普通术语）。
  static String normalizeType(dynamic raw) {
    final text = raw is String ? raw.trim().toLowerCase() : '';
    if (_types.contains(text)) return text;
    return _typeAliases[text] ?? GlossaryEntry.typeTerm;
  }
}
