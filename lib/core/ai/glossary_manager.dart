/// 翻译术语表管理器（术语表与人名一致性）。
///
/// 按「作品|语言」维度把术语条目持久化到 Hive box `translation_glossaries`，
/// 作品维度为空串（`''`）表示**全局术语表**（视频字幕等无作品身份的模块使用）；
/// 生效条目 = 全局 + 当前作品（同术语时作品级覆盖全局）。
///
/// 自动提取的新词经 [upsertExtracted] 落库：新词插入、同译合并别名、
/// 异译只记冲突**绝不覆盖**既定译名；冲突存 `translation_glossary_conflicts`，
/// 由用户经 [resolveConflict] 裁决。术语版本号存 `translation_glossary_meta`，
/// 供缓存指纹判断条目是否变更。
///
/// 提示词注入统一经 [PromptBuilder.glossarySection]（core/ai/prompt_builder.dart），
/// 响应侧冲突检测走 [detectConflicts]（日志告警）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// 单条术语。
class GlossaryEntry {
  final String id;

  /// 原文术语（日文/英文名词原样）。
  final String term;

  /// 统一译名（全书唯一）。
  final String preferred;

  /// 可接受的别名（冲突检测时不告警）。
  final List<String> aliases;

  /// 备注（音译理由 / 出场说明等，不注入提示词正文，仅编辑器展示）。
  final String note;

  /// 词条类型：`term`（普通术语）/ `person` / `place` / `org` /
  /// `appellation`（称谓）/ `honorific`（敬称）/ `speech`（口癖）/
  /// `fixed_expression`（固定表达）。决定匹配与注入策略。
  final String type;

  /// 性别（人名条目可选，供译文选词参考；空串表示未标注）。
  final String gender;

  /// 首次出现章节序号（提取时记录；null 表示手工条目或未知）。
  final int? firstChapter;

  /// 条目状态：`ok`（正常）/ `conflict`（与既有译名冲突，待裁决）。
  final String status;

  static const String typeTerm = 'term';
  static const String statusOk = 'ok';
  static const String statusConflict = 'conflict';

  const GlossaryEntry({
    required this.id,
    required this.term,
    required this.preferred,
    this.aliases = const <String>[],
    this.note = '',
    this.type = typeTerm,
    this.gender = '',
    this.firstChapter,
    this.status = statusOk,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'term': term,
        'preferred': preferred,
        'aliases': aliases,
        if (note.isNotEmpty) 'note': note,
        if (type != typeTerm) 'type': type,
        if (gender.isNotEmpty) 'gender': gender,
        if (firstChapter != null) 'firstChapter': firstChapter,
        if (status != statusOk) 'status': status,
      };

  factory GlossaryEntry.fromJson(Map<String, dynamic> json) => GlossaryEntry(
        id: json['id'] as String? ?? '',
        term: json['term'] as String? ?? '',
        preferred: json['preferred'] as String? ?? '',
        aliases: <String>[
          for (final a in (json['aliases'] as List<dynamic>? ?? const <dynamic>[]))
            a as String? ?? '',
        ].where((a) => a.isNotEmpty).toList(),
        note: json['note'] as String? ?? '',
        type: json['type'] as String? ?? typeTerm,
        gender: json['gender'] as String? ?? '',
        firstChapter: json['firstChapter'] is num
            ? (json['firstChapter'] as num).toInt()
            : null,
        status: json['status'] as String? ?? statusOk,
      );

  GlossaryEntry copyWith({
    String? id,
    String? term,
    String? preferred,
    List<String>? aliases,
    String? note,
    String? type,
    String? gender,
    int? firstChapter,
    String? status,
  }) =>
      GlossaryEntry(
        id: id ?? this.id,
        term: term ?? this.term,
        preferred: preferred ?? this.preferred,
        aliases: aliases ?? this.aliases,
        note: note ?? this.note,
        type: type ?? this.type,
        gender: gender ?? this.gender,
        firstChapter: firstChapter ?? this.firstChapter,
        status: status ?? this.status,
      );
}

/// 自动提取发现「同一术语存在不同译名」时的待裁决冲突。
///
/// 冲突只记录、不覆盖既定译名；用户裁决后才写入作品级覆盖或保留原译名。
class GlossaryConflict {
  final String id;
  final String workId;
  final String lang;
  final String term;

  /// 既有译名（作品级或全局生效条目）。
  final String existingPreferred;

  /// 自动提取在本批译文中实际观察到的译法。
  final String proposed;

  /// 词条类型（采用新译法时写入新条目）。
  final String type;
  final String chapterId;
  final String chapterTitle;
  final int createdAt;
  final bool resolved;

  const GlossaryConflict({
    required this.id,
    required this.workId,
    required this.lang,
    required this.term,
    required this.existingPreferred,
    required this.proposed,
    this.type = GlossaryEntry.typeTerm,
    this.chapterId = '',
    this.chapterTitle = '',
    required this.createdAt,
    this.resolved = false,
  });

  /// 同一作品 + 语言 + 术语只保留一条待裁决记录。
  static String idFor(String workId, String lang, String term) =>
      '$workId|$lang|$term';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'workId': workId,
        'lang': lang,
        'term': term,
        'existingPreferred': existingPreferred,
        'proposed': proposed,
        if (type != GlossaryEntry.typeTerm) 'type': type,
        if (chapterId.isNotEmpty) 'chapterId': chapterId,
        if (chapterTitle.isNotEmpty) 'chapterTitle': chapterTitle,
        'createdAt': createdAt,
        if (resolved) 'resolved': true,
      };

  factory GlossaryConflict.fromJson(Map<String, dynamic> json) =>
      GlossaryConflict(
        id: json['id'] as String? ?? '',
        workId: json['workId'] as String? ?? '',
        lang: json['lang'] as String? ?? '',
        term: json['term'] as String? ?? '',
        existingPreferred: json['existingPreferred'] as String? ?? '',
        proposed: json['proposed'] as String? ?? '',
        type: json['type'] as String? ?? GlossaryEntry.typeTerm,
        chapterId: json['chapterId'] as String? ?? '',
        chapterTitle: json['chapterTitle'] as String? ?? '',
        createdAt: json['createdAt'] is num
            ? (json['createdAt'] as num).toInt()
            : 0,
        resolved: json['resolved'] == true,
      );

  GlossaryConflict copyWith({
    String? existingPreferred,
    String? proposed,
    String? type,
    String? chapterId,
    String? chapterTitle,
    int? createdAt,
    bool? resolved,
  }) =>
      GlossaryConflict(
        id: id,
        workId: workId,
        lang: lang,
        term: term,
        existingPreferred: existingPreferred ?? this.existingPreferred,
        proposed: proposed ?? this.proposed,
        type: type ?? this.type,
        chapterId: chapterId ?? this.chapterId,
        chapterTitle: chapterTitle ?? this.chapterTitle,
        createdAt: createdAt ?? this.createdAt,
        resolved: resolved ?? this.resolved,
      );
}

/// 冲突裁决方向。
enum GlossaryConflictChoice {
  /// 采用自动提取观察到的新译法（写作品级覆盖）。
  proposed,

  /// 保留既定译名（若作品级条目标了冲突状态则恢复）。
  existing,
}

/// 自动提取落库统计。
class GlossaryUpsertSummary {
  final int inserted;
  final int merged;
  final int conflicts;

  const GlossaryUpsertSummary({
    this.inserted = 0,
    this.merged = 0,
    this.conflicts = 0,
  });

  static const GlossaryUpsertSummary empty = GlossaryUpsertSummary();

  /// 真正改变提示词术语表的条目数（冲突不计）。
  int get changed => inserted + merged;

  bool get isEmpty => inserted == 0 && merged == 0 && conflicts == 0;
}

/// 术语表管理器——Hive box `translation_glossaries`，键 `workId|lang`。
class GlossaryManager {
  GlossaryManager({Box<dynamic>? box}) : _box = box;

  static const String boxName = 'translation_glossaries';

  /// 待裁决冲突（键 = [GlossaryConflict.idFor]，值 = JSON 字符串）。
  static const String conflictBoxName = 'translation_glossary_conflicts';

  /// 术语版本号（值 = 写次数），供翻译缓存指纹判断术语是否变更。
  static const String metaBoxName = 'translation_glossary_meta';

  /// 全局术语表的 workId 占位（视频字幕等无作品身份的模块）。
  static const String globalWorkId = '';

  Box<dynamic>? _box;
  Box<dynamic>? _conflictBox;
  Box<dynamic>? _metaBox;

  Future<void> init() async {
    if (_box != null) return;
    if (Hive.isBoxOpen(boxName)) {
      _box = Hive.box(boxName);
      return;
    }
    _box = await Hive.openBox(boxName);
  }

  Future<Box<dynamic>> _ensureBox() async {
    if (_box != null) return _box!;
    await init();
    return _box!;
  }

  Future<Box<dynamic>> _ensureConflictBox() async {
    if (_conflictBox != null) return _conflictBox!;
    if (Hive.isBoxOpen(conflictBoxName)) {
      _conflictBox = Hive.box(conflictBoxName);
    } else {
      _conflictBox = await Hive.openBox(conflictBoxName);
    }
    return _conflictBox!;
  }

  Future<Box<dynamic>> _ensureMetaBox() async {
    if (_metaBox != null) return _metaBox!;
    if (Hive.isBoxOpen(metaBoxName)) {
      _metaBox = Hive.box(metaBoxName);
    } else {
      _metaBox = await Hive.openBox(metaBoxName);
    }
    return _metaBox!;
  }

  static String keyFor(String workId, String lang) => '$workId|$lang';

  Future<List<GlossaryEntry>> _readKey(String key) async {
    final box = await _ensureBox();
    final raw = box.get(key);
    if (raw is! String || raw.isEmpty) return const <GlossaryEntry>[];
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return const <GlossaryEntry>[];
      return <GlossaryEntry>[
        for (final dynamic item in decoded)
          if (item is Map<String, dynamic>) GlossaryEntry.fromJson(item),
      ];
    } on Object {
      return const <GlossaryEntry>[]; // 损坏数据按空表处理。
    }
  }

  Future<void> _write(
    String workId,
    String lang,
    List<GlossaryEntry> entries, {
    bool bumpRevision = true,
  }) async {
    final box = await _ensureBox();
    final key = keyFor(workId, lang);
    if (entries.isEmpty) {
      await box.delete(key);
    } else {
      await box.put(
        key,
        jsonEncode(<Map<String, dynamic>>[for (final e in entries) e.toJson()]),
      );
    }
    if (bumpRevision) await _bumpRevision(workId, lang);
  }

  static String _revisionKey(String workId, String lang) => 'rev|$workId|$lang';

  Future<int> _readRevision(String workId, String lang) async {
    final box = await _ensureMetaBox();
    final value = box.get(_revisionKey(workId, lang));
    return value is int ? value : 0;
  }

  Future<void> _bumpRevision(String workId, String lang) async {
    final box = await _ensureMetaBox();
    final key = _revisionKey(workId, lang);
    final current = box.get(key);
    await box.put(key, (current is int ? current : 0) + 1);
  }

  /// 术语版本指纹：全局 + 作品级写次数拼接；术语增删改（含裁决采纳）
  /// 都会改变指纹，供翻译缓存判断是否需要重译。
  Future<String> glossaryRevision(String? workId, String lang) async {
    final global = await _readRevision(globalWorkId, lang);
    if (workId == null || workId.isEmpty || workId == globalWorkId) {
      return 'g$global';
    }
    final work = await _readRevision(workId, lang);
    return 'g$global.w$work';
  }

  /// 某作品（或全局）某语言的全部术语。
  Future<List<GlossaryEntry>> entriesFor(String workId, String lang) =>
      _readKey(keyFor(workId, lang));

  /// 生效术语表：全局 + 作品级（同 term 时作品级覆盖全局，保序去重）。
  Future<List<GlossaryEntry>> effectiveEntries(String? workId, String lang) async {
    final global = await _readKey(keyFor(globalWorkId, lang));
    if (workId == null || workId.isEmpty || workId == globalWorkId) return global;
    final work = await _readKey(keyFor(workId, lang));
    if (work.isEmpty) return global;
    final merged = <GlossaryEntry>[...global];
    final seen = <String>{for (final e in global) e.term};
    for (final e in work) {
      if (seen.contains(e.term)) {
        final idx = merged.indexWhere((g) => g.term == e.term);
        if (idx >= 0) merged[idx] = e;
      } else {
        merged.add(e);
        seen.add(e.term);
      }
    }
    return merged;
  }

  /// 生效术语表（带语言回落）：优先 [lang]（各功能自己的目标语言），
  /// 该语言下完全无条目时回落 [fallbackLang]（小说翻译的主目标语言），
  /// 避免多模块语言不一致时术语表「失明」。
  Future<List<GlossaryEntry>> effectiveEntriesWithFallback(
    String? workId,
    String lang,
    String fallbackLang,
  ) async {
    final primary = await effectiveEntries(workId, lang);
    if (primary.isNotEmpty || lang == fallbackLang) return primary;
    return effectiveEntries(workId, fallbackLang);
  }

  /// 新增或更新（按 id 匹配；id 为空时生成）。返回保存后的完整列表。
  Future<List<GlossaryEntry>> saveEntry(
    String workId,
    String lang,
    GlossaryEntry entry,
  ) async {
    final list = <GlossaryEntry>[...await _readKey(keyFor(workId, lang))];
    final id = entry.id.isEmpty
        ? 'g${DateTime.now().microsecondsSinceEpoch}'
        : entry.id;
    final next = entry.id.isEmpty ? entry.copyWith(id: id) : entry;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx >= 0) {
      list[idx] = next;
    } else {
      list.add(next);
    }
    await _write(workId, lang, list);
    return list;
  }

  /// 删除条目。返回删除后的完整列表。
  Future<List<GlossaryEntry>> removeEntry(
    String workId,
    String lang,
    String id,
  ) async {
    final list = <GlossaryEntry>[...await _readKey(keyFor(workId, lang))];
    list.removeWhere((e) => e.id == id);
    await _write(workId, lang, list);
    return list;
  }

  /// 用 [entries] 整体替换某作品（或全局）的术语表（导入用）。
  Future<void> replaceAll(
    String workId,
    String lang,
    List<GlossaryEntry> entries,
  ) async {
    await _write(workId, lang, entries);
  }

  /// 导出 JSON 字符串（术语数组，跨设备迁移用）。
  static String exportJson(List<GlossaryEntry> entries) => jsonEncode(
        <Map<String, dynamic>>[for (final e in entries) e.toJson()],
      );

  /// 解析导入的 JSON；格式非法时抛 [FormatException]。
  static List<GlossaryEntry> parseImportJson(String raw) {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('术语表格式应为数组');
    return <GlossaryEntry>[
      for (final dynamic item in decoded)
        if (item is Map) GlossaryEntry.fromJson(item.cast<String, dynamic>()),
    ];
  }

  /// 导入合并：同 term 覆盖、新 term 追加（写入 [workId] 表）。返回合并后列表。
  Future<List<GlossaryEntry>> importMerge(
    String workId,
    String lang,
    List<GlossaryEntry> incoming,
  ) async {
    final list = <GlossaryEntry>[...await _readKey(keyFor(workId, lang))];
    for (final e in incoming) {
      if (e.term.trim().isEmpty) continue;
      final idx = list.indexWhere((x) => x.term == e.term);
      if (idx >= 0) {
        list[idx] = e.copyWith(id: list[idx].id);
      } else {
        list.add(e.id.isEmpty
            ? e.copyWith(id: 'g${DateTime.now().microsecondsSinceEpoch}_${list.length}')
            : e);
      }
    }
    await _write(workId, lang, list);
    return list;
  }

  /// 自动提取结果落库：新词插入、同译合并别名、异译只记冲突不覆盖。
  ///
  /// - [workId] 为空时写入全局表；小说链路始终传作品 id；
  /// - 冲突记录按「作品 + 语言 + 术语」去重，同一术语只保留一条待裁决；
  /// - 只有真正改变术语表（插入/合并）才递增版本号，冲突记录不使缓存失效。
  Future<GlossaryUpsertSummary> upsertExtracted(
    String workId,
    String lang,
    List<GlossaryEntry> extracted, {
    String chapterId = '',
    String chapterTitle = '',
    int? chapterIndex,
  }) async {
    final scope = workId.trim().isEmpty ? globalWorkId : workId;
    final workList = <GlossaryEntry>[
      ...await _readKey(keyFor(scope, lang)),
    ];
    final globalList = scope == globalWorkId
        ? const <GlossaryEntry>[]
        : await _readKey(keyFor(globalWorkId, lang));
    final effective = <String, GlossaryEntry>{
      for (final e in globalList) e.term: e,
      for (final e in workList) e.term: e,
    };
    var inserted = 0;
    var merged = 0;
    var conflicts = 0;
    var dirty = false;
    var semanticChanges = false;

    for (final candidate in extracted) {
      final term = candidate.term.trim();
      final preferred = candidate.preferred.trim();
      if (term.isEmpty || preferred.isEmpty) continue;
      final workIdx = workList.indexWhere((e) => e.term == term);
      final existing = workIdx >= 0 ? workList[workIdx] : effective[term];
      if (existing == null) {
        final entry = GlossaryEntry(
          id: 'g${DateTime.now().microsecondsSinceEpoch}_$inserted',
          term: term,
          preferred: preferred,
          aliases: candidate.aliases,
          note: candidate.note,
          type: candidate.type,
          firstChapter: chapterIndex,
        );
        workList.add(entry);
        effective[term] = entry;
        inserted++;
        dirty = true;
        semanticChanges = true;
        continue;
      }

      final accepted = <String>{existing.preferred, ...existing.aliases};
      if (accepted.contains(preferred)) {
        // 同译：只合并新别名与类型信息；命中全局条目时无需重复落作品级。
        if (workIdx < 0) continue;
        final current = workList[workIdx];
        final aliases = <String>{...current.aliases, ...candidate.aliases}
          ..remove(current.preferred)
          ..remove('');
        final next = current.copyWith(
          aliases: aliases.toList(),
          type: current.type == GlossaryEntry.typeTerm
              ? candidate.type
              : current.type,
          note: current.note.isEmpty ? candidate.note : current.note,
        );
        if (jsonEncode(next.toJson()) != jsonEncode(current.toJson())) {
          workList[workIdx] = next;
          effective[term] = next;
          merged++;
          dirty = true;
          semanticChanges = true;
        }
        continue;
      }

      // 异译：记录冲突待裁决，绝不覆盖既定译名。
      await _recordConflict(
        scope,
        lang,
        term: term,
        existingPreferred: existing.preferred,
        proposed: preferred,
        type: candidate.type,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
      );
      conflicts++;
      if (workIdx >= 0 &&
          workList[workIdx].status != GlossaryEntry.statusConflict) {
        workList[workIdx] = workList[workIdx].copyWith(
          status: GlossaryEntry.statusConflict,
        );
        dirty = true;
      }
    }

    if (dirty) {
      await _write(scope, lang, workList, bumpRevision: semanticChanges);
    }
    if (inserted > 0 || merged > 0 || conflicts > 0) {
      GlossaryChangeNotifier.instance.notifyChanged();
    }
    return GlossaryUpsertSummary(
      inserted: inserted,
      merged: merged,
      conflicts: conflicts,
    );
  }

  /// 未裁决冲突列表；[workId]/[lang] 为空时不过滤。
  Future<List<GlossaryConflict>> openConflicts({
    String? workId,
    String? lang,
  }) async {
    final box = await _ensureConflictBox();
    final result = <GlossaryConflict>[];
    for (final raw in box.values) {
      if (raw is! String || raw.isEmpty) continue;
      final conflict = _decodeConflict(raw);
      if (conflict == null || conflict.resolved) continue;
      if (workId != null && conflict.workId != workId) continue;
      if (lang != null && conflict.lang != lang) continue;
      result.add(conflict);
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  /// 裁决冲突：采用新译法写作品级覆盖；保留原译名仅清除待裁决状态。
  Future<GlossaryUpsertSummary> resolveConflict(
    String id,
    GlossaryConflictChoice choice,
  ) async {
    final box = await _ensureConflictBox();
    final raw = box.get(id);
    if (raw is! String || raw.isEmpty) return GlossaryUpsertSummary.empty;
    final conflict = _decodeConflict(raw);
    if (conflict == null || conflict.resolved) {
      return GlossaryUpsertSummary.empty;
    }

    var inserted = 0;
    var merged = 0;
    var semanticChanges = false;
    var dirty = false;
    final list = <GlossaryEntry>[
      ...await _readKey(keyFor(conflict.workId, conflict.lang)),
    ];
    final idx = list.indexWhere((e) => e.term == conflict.term);

    if (choice == GlossaryConflictChoice.proposed) {
      if (idx >= 0) {
        final current = list[idx];
        final aliases = <String>{...current.aliases}
          ..remove(conflict.proposed)
          ..add(conflict.existingPreferred)
          ..remove('');
        final next = current.copyWith(
          preferred: conflict.proposed,
          aliases: aliases.toList(),
          status: GlossaryEntry.statusOk,
        );
        if (jsonEncode(next.toJson()) != jsonEncode(current.toJson())) {
          list[idx] = next;
          dirty = true;
          semanticChanges = current.preferred != conflict.proposed;
          merged = semanticChanges ? 1 : 0;
        }
      } else {
        list.add(GlossaryEntry(
          id: 'g${DateTime.now().microsecondsSinceEpoch}',
          term: conflict.term,
          preferred: conflict.proposed,
          type: conflict.type,
        ));
        inserted = 1;
        dirty = true;
        semanticChanges = true;
      }
    } else if (idx >= 0 && list[idx].status != GlossaryEntry.statusOk) {
      list[idx] = list[idx].copyWith(status: GlossaryEntry.statusOk);
      dirty = true;
    }

    if (dirty) {
      await _write(
        conflict.workId,
        conflict.lang,
        list,
        bumpRevision: semanticChanges,
      );
    }
    await box.put(id, jsonEncode(conflict.copyWith(resolved: true).toJson()));
    GlossaryChangeNotifier.instance.notifyChanged();
    return GlossaryUpsertSummary(inserted: inserted, merged: merged);
  }

  Future<void> _recordConflict(
    String workId,
    String lang, {
    required String term,
    required String existingPreferred,
    required String proposed,
    required String type,
    required String chapterId,
    required String chapterTitle,
  }) async {
    final box = await _ensureConflictBox();
    final id = GlossaryConflict.idFor(workId, lang, term);
    final raw = box.get(id);
    final existing = raw is String ? _decodeConflict(raw) : null;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (existing != null && !existing.resolved) {
      // 同一术语只留一条待裁决；新证据刷新「本次译法」与出处。
      if (existing.existingPreferred != existingPreferred ||
          existing.proposed != proposed ||
          existing.type != type ||
          existing.chapterId != chapterId ||
          existing.chapterTitle != chapterTitle) {
        await box.put(
          id,
          jsonEncode(existing
              .copyWith(
                existingPreferred: existingPreferred,
                proposed: proposed,
                type: type,
                chapterId: chapterId,
                chapterTitle: chapterTitle,
                createdAt: now,
              )
              .toJson()),
        );
      }
      return;
    }
    await box.put(
      id,
      jsonEncode(GlossaryConflict(
        id: id,
        workId: workId,
        lang: lang,
        term: term,
        existingPreferred: existingPreferred,
        proposed: proposed,
        type: type,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        createdAt: now,
      ).toJson()),
    );
  }

  static GlossaryConflict? _decodeConflict(String raw) {
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return GlossaryConflict.fromJson(decoded);
      }
    } on Object {
      // 损坏数据按无冲突处理。
    }
    return null;
  }

  /// 术语冲突检测（日志告警通道）：同一术语在原文出现，但译文既非
  /// 首选译名也非任何别名时返回告警描述。
  ///
  /// 纯函数、零副作用，供三个模块在解析译文后调用（当前仅写日志，
  /// 修正通道与 UI 呈现属后续迭代）。
  static List<String> detectConflicts(
    List<GlossaryEntry> entries,
    List<String> sources,
    List<String> translations,
  ) {
    if (entries.isEmpty || sources.length != translations.length) {
      return const <String>[];
    }
    final warnings = <String>[];
    for (final e in entries) {
      if (e.term.trim().isEmpty || e.preferred.trim().isEmpty) continue;
      final ok = <String>{e.preferred, ...e.aliases};
      var hit = false;
      var bad = <String>{};
      for (var i = 0; i < sources.length; i++) {
        if (!sources[i].contains(e.term)) continue;
        hit = true;
        if (!ok.any(translations[i].contains)) {
          bad.add(translations[i].isEmpty ? '（空译文）' : translations[i]);
        }
      }
      if (hit && bad.isNotEmpty) {
        warnings.add('术语「${e.term}」应译为「${e.preferred}」，'
            '实际出现：${bad.take(3).join(' / ')}');
      }
    }
    return warnings;
  }
}

/// 术语表变更通知（编辑器与设置页刷新用；轻量 ChangeNotifier）。
class GlossaryChangeNotifier extends ChangeNotifier {
  GlossaryChangeNotifier._();
  static final GlossaryChangeNotifier instance = GlossaryChangeNotifier._();

  void notifyChanged() => notifyListeners();
}
