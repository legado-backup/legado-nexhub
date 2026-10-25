/// 多角色朗读路由器 + 角色卡存储单测。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/novel/novel_http_tts_config.dart';
import 'package:nexhub/core/novel/novel_speech_segmenter.dart';
import 'package:nexhub/core/novel/novel_tts_cast_store.dart';
import 'package:nexhub/core/novel/novel_tts_router.dart';

void main() {
  group('路由器：HTTP 域', () {
    test('角色卡绑定优先', () {
      final router = NovelTtsRouter(
        characters: const [
          NovelCastCharacter(
              name: '小明', httpVoiceId: 'xm-voice', gender: 'male'),
        ],
        httpConfig: const NovelHttpTtsConfig(
          defaultVoice: 'def',
          voiceByRole: {'小明': 'legacy-xm'},
        ),
      );
      final d = router.route('小明', SpeechGender.unknown);
      expect(d.httpVoice, 'xm-voice');
      expect(d.source, NovelTtsRouteSource.binding);
    });

    test('别名命中同一角色', () {
      final router = NovelTtsRouter(
        characters: const [
          NovelCastCharacter(
              name: '萧炎', aliases: ['炎哥', '小炎子'], httpVoiceId: 'xy'),
        ],
        httpConfig: const NovelHttpTtsConfig(defaultVoice: 'def'),
      );
      expect(router.route('炎哥', SpeechGender.unknown).httpVoice, 'xy');
      expect(router.route('小炎子', SpeechGender.unknown).httpVoice, 'xy');
      expect(router.canonicalName('炎哥'), '萧炎');
    });

    test('停用角色跳过绑定走全局兜底', () {
      final router = NovelTtsRouter(
        characters: const [
          NovelCastCharacter(
              name: '小明', httpVoiceId: 'xm', enabled: false),
        ],
        httpConfig: const NovelHttpTtsConfig(defaultVoice: 'def'),
      );
      final d = router.route('小明', SpeechGender.unknown);
      expect(d.httpVoice, 'def');
      expect(d.source, NovelTtsRouteSource.engineDefault);
    });

    test('旧版 voiceByRole 兜底生效（名字与别名都可命中）', () {
      final router = NovelTtsRouter(
        characters: const [],
        httpConfig: const NovelHttpTtsConfig(
          defaultVoice: 'def',
          voiceByRole: {'小明': 'legacy-xm'},
        ),
      );
      final d = router.route('小明', SpeechGender.unknown);
      expect(d.httpVoice, 'legacy-xm');
      expect(d.source, NovelTtsRouteSource.legacyMap);
    });

    test('性别兜底槽：句内判女声 + 角色卡女性别都走 femaleVoice', () {
      final router = NovelTtsRouter(
        characters: const [
          NovelCastCharacter(name: '林黛玉', gender: 'female'),
        ],
        httpConfig: const NovelHttpTtsConfig(
          defaultVoice: 'def',
          femaleVoice: 'fv',
          maleVoice: 'mv',
        ),
      );
      expect(router.route('林黛玉', SpeechGender.unknown).httpVoice, 'fv');
      expect(router.route(quoteRole, SpeechGender.female).httpVoice, 'fv');
      expect(router.route(quoteRole, SpeechGender.male).httpVoice, 'mv');
      expect(router.route(quoteRole, SpeechGender.unknown).httpVoice, 'def');
    });

    test('旁白永远走旁白槽，空槽回落默认', () {
      final router = NovelTtsRouter(
        characters: const [],
        httpConfig: const NovelHttpTtsConfig(
          defaultVoice: 'def',
          narratorVoice: 'nar',
        ),
      );
      final d = router.route(narratorRole, SpeechGender.unknown);
      expect(d.httpVoice, 'nar');
      expect(d.source, NovelTtsRouteSource.narratorSlot);

      final router2 = NovelTtsRouter(
        characters: const [],
        httpConfig: const NovelHttpTtsConfig(defaultVoice: 'def'),
      );
      expect(router2.route(narratorRole, SpeechGender.unknown).httpVoice, 'def');
    });

    test('性别缺失时用角色卡性别补判', () {
      final router = NovelTtsRouter(
        characters: const [
          NovelCastCharacter(name: '小明', gender: 'male'),
        ],
        httpConfig: const NovelHttpTtsConfig(
          defaultVoice: 'def',
          maleVoice: 'mv',
        ),
      );
      expect(router.route('小明', SpeechGender.unknown).httpVoice, 'mv');
      expect(router.genderOf('小明'), SpeechGender.male);
    });
  });

  group('路由器：系统域', () {
    test('绑定 → 性别槽 → 空串（引擎默认）', () {
      final router = NovelTtsRouter(
        characters: const [
          NovelCastCharacter(name: '小明', systemVoiceName: 'zh-male-1'),
          NovelCastCharacter(name: '小红', gender: 'female'),
        ],
        httpConfig: const NovelHttpTtsConfig(defaultVoice: 'def'),
        systemSlots: const NovelTtsSystemSlots(
            narrator: 'sys-nar', male: 'sys-m', female: 'sys-f'),
      );
      expect(router.route('小明', SpeechGender.unknown).systemVoice, 'zh-male-1');
      expect(router.route('小红', SpeechGender.unknown).systemVoice, 'sys-f');
      expect(router.route('路人', SpeechGender.unknown).systemVoice, '');
      expect(router.route(narratorRole, SpeechGender.unknown).systemVoice, 'sys-nar');
    });

    test('旧版 voiceByRole 不跨域污染系统声音', () {
      final router = NovelTtsRouter(
        characters: const [],
        httpConfig: const NovelHttpTtsConfig(
          defaultVoice: 'def',
          voiceByRole: {'小明': 'legacy-xm'},
        ),
      );
      // legacy-xm 是 HTTP voice id，不应被当作系统声音名。
      expect(router.route('小明', SpeechGender.unknown).systemVoice, '');
    });
  });

  group('角色卡存储（Hive）', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('tts_cast_test_');
      Hive.init(tmpDir.path);
    });

    tearDown(() async {
      await Hive.close();
      await tmpDir.delete(recursive: true);
    });

    test('upsert 新增与合并更新 + round-trip', () async {
      final store = NovelTtsCastStore();
      await store.upsert('novel-1', '小明',
          gender: NovelCastGender.male, httpVoiceId: 'xm');
      await store.upsert('novel-1', '小明',
          aliases: ['明明'], mergeAliases: true, source: NovelCastSource.ai);

      final chars = await store.loadCharacters('novel-1');
      expect(chars.length, 1);
      expect(chars.first.name, '小明');
      expect(chars.first.aliases, contains('明明'));
      expect(chars.first.gender, NovelCastGender.male); // 未传字段保持
      expect(chars.first.httpVoiceId, 'xm');
      expect(chars.first.source, NovelCastSource.ai);

      // 不同书互不影响。
      expect(await store.loadCharacters('novel-2'), isEmpty);
    });

    test('remove 删除指定角色', () async {
      final store = NovelTtsCastStore();
      await store.upsert('n1', '甲');
      await store.upsert('n1', '乙');
      await store.remove('n1', '甲');
      final chars = await store.loadCharacters('n1');
      expect(chars.map((c) => c.name), ['乙']);
    });

    test('坏数据回落空集合', () async {
      final store = NovelTtsCastStore();
      final box = await Hive.openBox<dynamic>(NovelTtsCastStore.boxName);
      await box.put('bad', 'not-json');
      expect(await store.loadCharacters('bad'), isEmpty);
    });
  });
}
