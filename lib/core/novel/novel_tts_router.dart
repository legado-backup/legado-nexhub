/// 小说多角色朗读——声音路由器（纯函数，可单测）。
///
/// 参考 legado_NG ReadAloudTtsRouter 的多级兜底链，按 nexhub 体量裁剪。
/// 两个音色域分开解析：
/// - **HTTP 域**（在线模板 TTS）：本书角色卡绑定 → 全局 voiceByRole（旧版
///   兼容）→ 性别兜底槽（男/女）→ 旁白槽 → defaultVoice；
/// - **系统域**（flutter_tts / OHOS 引擎）：本书角色卡绑定 → 性别兜底槽
///   （系统声音名）→ ''（引擎保持当前声音）。旧版 voiceByRole 是 HTTP
///   voice id，不跨域复用（避免把在线音色 id 当系统声音名）。
///
/// 旁白（[narratorRole]）永远走旁白槽；对白未命中任何绑定时按
/// [SpeechSegment.gender] 走性别槽。
library;

import 'novel_http_tts_config.dart';
import 'novel_speech_segmenter.dart';
import 'novel_tts_cast_store.dart';

/// 路由命中来源（面板展示/诊断用）。
enum NovelTtsRouteSource {
  /// 本书角色卡绑定。
  binding,

  /// 全局角色→音色映射（旧版 voiceByRole）。
  legacyMap,

  /// 性别兜底槽（男/女）。
  genderSlot,

  /// 旁白槽。
  narratorSlot,

  /// 默认音色 / 引擎当前声音。
  engineDefault,
}

/// 一次路由决策结果。
class NovelTtsRouteDecision {
  const NovelTtsRouteDecision({
    required this.httpVoice,
    required this.systemVoice,
    required this.source,
  });

  /// HTTP 域解析结果（模板 {voice} 的值）。
  final String httpVoice;

  /// 系统域解析结果（'' = 不切声音，保持引擎当前）。
  final String systemVoice;

  final NovelTtsRouteSource source;
}

/// 系统 TTS 声音三槽（旁白/男/女；存阅读器偏好，与 HTTP 配置分离）。
class NovelTtsSystemSlots {
  const NovelTtsSystemSlots({
    this.narrator = '',
    this.male = '',
    this.female = '',
  });

  final String narrator;
  final String male;
  final String female;
}

/// 声音路由器：一次构建（快照角色卡与配置），播放期零查询开销。
class NovelTtsRouter {
  NovelTtsRouter({
    required List<NovelCastCharacter> characters,
    required NovelHttpTtsConfig httpConfig,
    this.systemSlots = const NovelTtsSystemSlots(),
  })  : _httpConfig = httpConfig,
        _bindings = {
          for (final c in characters)
            if (c.enabled && c.name.trim().isNotEmpty) c.name.trim(): c,
        },
        _aliasIndex = _buildAliasIndex(characters);

  final NovelHttpTtsConfig _httpConfig;
  final Map<String, NovelCastCharacter> _bindings;
  // 别名/称谓 → 规范名（仅启用角色；同名别名先到先得，名字本身优先）。
  final Map<String, String> _aliasIndex;
  final NovelTtsSystemSlots systemSlots;

  static Map<String, String> _buildAliasIndex(
      List<NovelCastCharacter> characters) {
    final index = <String, String>{};
    for (final c in characters) {
      if (!c.enabled) continue;
      final canonical = c.name.trim();
      if (canonical.isEmpty) continue;
      index.putIfAbsent(canonical, () => canonical);
      for (final alias in c.aliases) {
        final a = alias.trim();
        if (a.isNotEmpty) index.putIfAbsent(a, () => canonical);
      }
    }
    return index;
  }

  /// 按角色名解析到规范名（本名或别名命中；未命中原样返回 trim 后的名字）。
  String canonicalName(String role) {
    final trimmed = role.trim();
    return _aliasIndex[trimmed] ?? trimmed;
  }

  /// 角色已知性别（角色卡命中时；判不出 unknown）。
  String genderOf(String role) {
    final canonical = canonicalName(role);
    return _bindings[canonical]?.gender ?? SpeechGender.unknown;
  }

  /// 完整路由决策。
  NovelTtsRouteDecision route(String role, String gender) {
    final isNarrator = role.trim() == narratorRole;
    final canonical = canonicalName(role);
    final character = _bindings[canonical];
    final effectiveGender = _normalizeGender(gender) == SpeechGender.unknown
        ? character?.gender ?? SpeechGender.unknown
        : _normalizeGender(gender);

    // ── 系统域：绑定 → 旁白槽 → 性别槽 → 引擎默认。
    final systemVoice = isNarrator
        ? systemSlots.narrator
        : (character?.systemVoiceName.isNotEmpty ?? false
            ? character!.systemVoiceName
            : _systemGenderVoice(effectiveGender));

    // ── HTTP 域：绑定 → 旧版映射 → 旁白槽 → 性别槽 → defaultVoice。
    String httpVoice;
    NovelTtsRouteSource source;
    if (isNarrator) {
      httpVoice =
          _httpConfig.narratorVoice.isNotEmpty ? _httpConfig.narratorVoice : _httpConfig.defaultVoice;
      source = _httpConfig.narratorVoice.isNotEmpty
          ? NovelTtsRouteSource.narratorSlot
          : NovelTtsRouteSource.engineDefault;
    } else if (character != null && character.httpVoiceId.isNotEmpty) {
      httpVoice = character.httpVoiceId;
      source = NovelTtsRouteSource.binding;
    } else if ((_httpConfig.voiceByRole[role.trim()] ??
                _httpConfig.voiceByRole[canonical] ?? '')
            .isNotEmpty) {
      httpVoice = _httpConfig.voiceByRole[role.trim()] ??
          _httpConfig.voiceByRole[canonical]!;
      source = NovelTtsRouteSource.legacyMap;
    } else {
      final genderVoice = _httpGenderVoice(effectiveGender);
      if (genderVoice.isNotEmpty) {
        httpVoice = genderVoice;
        source = NovelTtsRouteSource.genderSlot;
      } else {
        httpVoice = _httpConfig.defaultVoice;
        source = NovelTtsRouteSource.engineDefault;
      }
    }
    return NovelTtsRouteDecision(
      httpVoice: httpVoice,
      systemVoice: systemVoice,
      source: source,
    );
  }

  String _httpGenderVoice(String gender) => switch (gender) {
        SpeechGender.male => _httpConfig.maleVoice,
        SpeechGender.female => _httpConfig.femaleVoice,
        _ => '',
      };

  String _systemGenderVoice(String gender) => switch (gender) {
        SpeechGender.male => systemSlots.male,
        SpeechGender.female => systemSlots.female,
        _ => '',
      };

  static String _normalizeGender(String gender) =>
      (gender == SpeechGender.male || gender == SpeechGender.female)
          ? gender
          : SpeechGender.unknown;
}
