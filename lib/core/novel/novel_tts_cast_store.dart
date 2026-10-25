/// 小说多角色朗读——每本书的角色卡存储。
///
/// 参考 legado_NG BookCharacter 简化而来：角色卡 = 名字 + 别名 + 性别 +
/// 启用开关 + 两个音色域的绑定（在线 HTTP TTS 的 voice id 与系统 TTS 的
/// 声音名分开存，切换引擎互不污染）。
///
/// 持久化：Hive box `novel_tts_cast`，key = novelId，value = 整本角色卡
/// 列表的 JSON（模式仿 [NovelTranslationManager]）。手动绑定（manual）
/// 与 AI 归因自动建卡（ai）同池存储，`source` 区分来源。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// 单张角色卡。
@immutable
class NovelCastCharacter {
  const NovelCastCharacter({
    required this.name,
    this.aliases = const <String>[],
    this.gender = NovelCastGender.unknown,
    this.enabled = true,
    this.source = NovelCastSource.manual,
    this.httpVoiceId = '',
    this.systemVoiceName = '',
    this.updatedAt = 0,
  });

  /// 角色规范名（分句器/AI 归因对齐到这个名字）。
  final String name;

  /// 别名/外号/称谓（路由按名字或别名命中即视为该角色）。
  final List<String> aliases;

  /// 性别（[NovelCastGender]；unknown 时性别兜底槽不生效）。
  final String gender;

  /// 停用后路由跳过该角色（回落全局兜底）。
  final bool enabled;

  /// 卡片来源：手动添加 / AI 归因自动发现。
  final String source;

  /// 在线 HTTP TTS 音色 id（空 = 不绑定，走全局兜底链）。
  final String httpVoiceId;

  /// 系统 TTS 声音名（Android/Windows 引擎的声音标识；空 = 不绑定）。
  final String systemVoiceName;

  final int updatedAt;

  NovelCastCharacter copyWith({
    String? name,
    List<String>? aliases,
    String? gender,
    bool? enabled,
    String? source,
    String? httpVoiceId,
    String? systemVoiceName,
    int? updatedAt,
}) =>
      NovelCastCharacter(
        name: name ?? this.name,
        aliases: aliases ?? this.aliases,
        gender: gender ?? this.gender,
        enabled: enabled ?? this.enabled,
        source: source ?? this.source,
        httpVoiceId: httpVoiceId ?? this.httpVoiceId,
        systemVoiceName: systemVoiceName ?? this.systemVoiceName,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'aliases': aliases,
        'gender': gender,
        'enabled': enabled,
        'source': source,
        'httpVoiceId': httpVoiceId,
        'systemVoiceName': systemVoiceName,
        'updatedAt': updatedAt,
      };

  factory NovelCastCharacter.fromJson(Map<String, dynamic> json) =>
      NovelCastCharacter(
        name: json['name'] as String? ?? '',
        aliases: <String>[
          for (final a in (json['aliases'] as List<dynamic>? ?? <dynamic>[]))
            a as String? ?? '',
        ]..removeWhere((a) => a.isEmpty),
        gender: json['gender'] as String? ?? NovelCastGender.unknown,
        enabled: json['enabled'] as bool? ?? true,
        source: json['source'] as String? ?? NovelCastSource.manual,
        httpVoiceId: json['httpVoiceId'] as String? ?? '',
        systemVoiceName: json['systemVoiceName'] as String? ?? '',
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

/// 性别常量（与 [SpeechGender] 值一致）。
abstract final class NovelCastGender {
  static const String male = 'male';
  static const String female = 'female';
  static const String unknown = 'unknown';
}

/// 卡片来源常量。
abstract final class NovelCastSource {
  static const String manual = 'manual';
  static const String ai = 'ai';
}

/// 每本书的角色卡集合（整本读写，避免细粒度合并冲突）。
@immutable
class NovelCastBook {
  const NovelCastBook({this.characters = const <NovelCastCharacter>[]});

  final List<NovelCastCharacter> characters;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'characters': <Map<String, dynamic>>[for (final c in characters) c.toJson()],
      };

  factory NovelCastBook.fromJson(Map<String, dynamic> json) => NovelCastBook(
        characters: <NovelCastCharacter>[
          for (final c in (json['characters'] as List<dynamic>? ?? <dynamic>[]))
            if (c is Map<String, dynamic>) NovelCastCharacter.fromJson(c),
        ],
      );
}

/// 角色卡存储（Hive）。变更后广播通知，角色面板/路由快照据此刷新。
class NovelTtsCastStore extends ChangeNotifier {
  NovelTtsCastStore({Box<dynamic>? box}) : _boxOverride = box;

  static const String boxName = 'novel_tts_cast';

  final Box<dynamic>? _boxOverride;
  Box<dynamic>? _box;

  static final NovelTtsCastStore instance = NovelTtsCastStore();

  Future<void> init() async {
    if (_boxOverride != null || _box != null) return;
    if (Hive.isBoxOpen(boxName)) {
      _box = Hive.box(boxName);
      return;
    }
    _box = await Hive.openBox(boxName);
  }

  Future<Box<dynamic>> _ensureBox() async {
    final override = _boxOverride;
    if (override != null) return override;
    final box = _box;
    if (box != null) return box;
    await init();
    return _box!;
  }

  /// 读取整本角色卡（无记录返回空集合）。
  Future<NovelCastBook> loadBook(String novelId) async {
    final box = await _ensureBox();
    final raw = box.get(novelId);
    if (raw is! String || raw.isEmpty) return const NovelCastBook();
    try {
      return NovelCastBook.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return const NovelCastBook();
    }
  }

  Future<List<NovelCastCharacter>> loadCharacters(String novelId) async =>
      (await loadBook(novelId)).characters;

  /// 整本写回（调用方持有完整列表；写后广播）。
  Future<void> saveCharacters(
      String novelId, List<NovelCastCharacter> characters) async {
    final box = await _ensureBox();
    await box.put(
        novelId, jsonEncode(NovelCastBook(characters: characters).toJson()));
    notifyListeners();
  }

  /// 新增或按名字合并更新一张卡。
  ///
  /// 已存在同名卡时以 [updated] 字段覆盖（未变更字段传 null 保持原值）；
  /// [mergeAliases] 为 true 时别名取并集（AI 归因增量发现用）。
  Future<void> upsert(
    String novelId,
    String name, {
    List<String>? aliases,
    bool mergeAliases = false,
    String? gender,
    bool? enabled,
    String? source,
    String? httpVoiceId,
    String? systemVoiceName,
  }) async {
    final list = [...await loadCharacters(novelId)];
    final idx = list.indexWhere((c) => c.name == name);
    if (idx < 0) {
      list.add(NovelCastCharacter(
        name: name,
        aliases: aliases ?? const <String>[],
        gender: gender ?? NovelCastGender.unknown,
        enabled: enabled ?? true,
        source: source ?? NovelCastSource.manual,
        httpVoiceId: httpVoiceId ?? '',
        systemVoiceName: systemVoiceName ?? '',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    } else {
      final old = list[idx];
      var next = old.copyWith(
        gender: gender,
        enabled: enabled,
        source: source,
        httpVoiceId: httpVoiceId,
        systemVoiceName: systemVoiceName,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      if (aliases != null) {
        next = next.copyWith(
          aliases: mergeAliases
              ? (<String>{...old.aliases, ...aliases}.toList()..sort())
              : aliases,
        );
      }
      list[idx] = next;
    }
    await saveCharacters(novelId, list);
  }

  /// 删除一张卡（按规范名）。
  Future<void> remove(String novelId, String name) async {
    final list = [...await loadCharacters(novelId)]
      ..removeWhere((c) => c.name == name);
    await saveCharacters(novelId, list);
  }
}
