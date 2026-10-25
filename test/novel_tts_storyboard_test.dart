/// AI 分镜归因服务单测（假 AiChatClient + 内存 Hive）：
/// - prompt 组装（已知角色注入 / 待标注句 id）
/// - 结果解析（幻觉 id 丢弃 / 别名归一 / 置信度 clamp）
/// - 置信度门限合并（低置信不覆盖本地）
/// - 缓存命中（同指纹不再请求；角色身份/正文变化指纹失效；音色变化不失效）
/// - 新角色自动建卡（不覆盖已有卡）
/// - 未配置 AI / 请求失败 / 解析失败 → null 优雅降级
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/ai_chat_client.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart';
import 'package:nexhub/core/novel/novel_http_tts_player.dart';
import 'package:nexhub/core/novel/novel_speech_segmenter.dart';
import 'package:nexhub/core/novel/novel_tts_cast_store.dart';
import 'package:nexhub/features/novel/domain/novel_summary_service.dart';
import 'package:nexhub/features/novel/domain/novel_summary_settings.dart';
import 'package:nexhub/features/novel/domain/novel_tts_storyboard_service.dart';

/// 假设置：固定返回注入的配置（绕过 SharedPreferences）。
class _FakeSettings implements NovelSummarySettings {
  _FakeSettings(this.cfg);
  final NovelSummaryConfig cfg;

  @override
  Future<NovelSummaryConfig> getSummaryConfig() async => cfg;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// 假聊天客户端：记录 prompt、返回注入的 raw 响应。
class _FakeChat extends AiChatClient {
  _FakeChat({this.responder});

  final Future<String> Function(String system, String user)? responder;
  final List<(String, String)> prompts = <(String, String)>[];
  int calls = 0;

  @override
  Future<String> complete(List<AiEndpointConfig> endpoints,
      {required String system,
      required String user,
      double temperature = 0.1,
      int? maxTokens,
      Duration receiveTimeout = const Duration(seconds: 120)}) async {
    calls++;
    prompts.add((system, user));
    if (responder == null) throw Exception('network down');
    return responder!(system, user);
  }
}

const _configured = NovelSummaryConfig(
  baseUrl: 'https://ai.example/v1',
  apiKey: 'sk-test',
  model: 'gpt-test',
);

void main() {
  late Directory tmpDir;
  late Box<dynamic> box;
  late NovelTtsCastStore cast;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('storyboard_test_');
    Hive.init(tmpDir.path);
    box = await Hive.openBox<dynamic>(NovelTtsStoryboardService.boxName);
    cast = NovelTtsCastStore();
  });

  tearDown(() async {
    await Hive.close();
    await tmpDir.delete(recursive: true);
  });

  NovelTtsStoryboardService newService({
    required AiChatClient chat,
    NovelSummaryConfig cfg = _configured,
  }) =>
      NovelTtsStoryboardService(
        castStore: cast,
        settings: _FakeSettings(cfg),
        chatClient: chat,
        box: box,
      );

  test('未配置 AI（空 baseUrl）→ null 且不发请求', () async {
    final chat = _FakeChat(responder: (s, u) async => '{}');
    final svc = newService(
        chat: chat, cfg: const NovelSummaryConfig(baseUrl: ''));
    final r = await svc.attributeChapter(
        novelId: 'n1', chapterId: 'c1', paragraphs: const ['小明说：你好。']);
    expect(r, isNull);
    expect(chat.calls, 0);
  });

  test('请求失败 / JSON 解析失败 → null 优雅降级', () async {
    var svc = newService(chat: _FakeChat()); // responder null → throw
    var r = await svc.attributeChapter(
        novelId: 'n1', chapterId: 'c1', paragraphs: const ['小明说：你好。']);
    expect(r, isNull);

    svc = newService(
        chat: _FakeChat(responder: (s, u) async => '不是 JSON'));
    r = await svc.attributeChapter(
        novelId: 'n1', chapterId: 'c2', paragraphs: const ['小明说：你好。']);
    expect(r, isNull);
  });

  test('全旁白章节 → 空结果缓存，不发请求', () async {
    final chat = _FakeChat(responder: (s, u) async => '{}');
    final svc = newService(chat: chat);
    final r = await svc.attributeChapter(
        novelId: 'n1', chapterId: 'c1', paragraphs: const ['天亮了。他走了。']);
    expect(r, isNotNull);
    expect(r!.entries, isEmpty);
    expect(chat.calls, 0);
  });

  test('归因成功：别名归一 + 幻觉 id 丢弃 + 置信度门限 + 新角色建卡',
      () async {
    final chat = _FakeChat(responder: (s, u) async {
      return jsonEncode(<String, dynamic>{
        'units': [
          {
            'id': '0-0',
            'role': '炎哥', // AI 用了别名
            'gender': 'male',
            'confidence': 0.9,
          },
          {
            'id': '0-1',
            'role': '路人甲',
            'gender': 'unknown',
            'confidence': 0.3, // 低于门限
          },
          {
            'id': '9-9', // 幻觉 id
            'role': '幻觉',
            'gender': 'male',
            'confidence': 0.99,
          },
        ],
        'newCharacters': [
          {'name': '路人甲', 'gender': 'male', 'aliases': const []},
        ],
      });
    });
    await cast.upsert('n1', '萧炎',
        aliases: const ['炎哥'], gender: NovelCastGender.male);
    final svc = newService(chat: chat);

    final r = await svc.attributeChapter(
        novelId: 'n1',
        chapterId: 'c1',
        paragraphs: const ['萧炎说："第一句。" 有人说："第二句。"']);
    expect(r, isNotNull);
    // 别名归一到规范名。
    expect(r!.entries['0-0']?.role, '萧炎');
    // 幻觉 id 丢弃。
    expect(r.entries.containsKey('9-9'), isFalse);

    // provider：高置信覆盖本地角色。
    final unit0 = TtsSentenceUnit(
        paragraphIndex: 0,
        segIndex: 0,
        segment: segmentSpeech('萧炎说："第一句。"').first);
    expect(r.segmentFor(unit0).role, '萧炎');

    // 低置信（0-1）不覆盖：本地判定是「有人」，保持原样。
    final unit1 = TtsSentenceUnit(
        paragraphIndex: 0, segIndex: 1, segment: const SpeechSegment(text: '第二句。', role: '有人', sourceRole: '有人'));
    expect(r.segmentFor(unit1).role, '有人');

    // 新角色自动建卡（source=ai）。
    final chars = await cast.loadCharacters('n1');
    expect(chars.map((c) => c.name), containsAll(<String>['萧炎', '路人甲']));
    expect(chars.firstWhere((c) => c.name == '路人甲').source,
        NovelCastSource.ai);
  });

  test('缓存命中：同指纹不再请求；角色身份/正文变化失效；音色变化不失效',
      () async {
    var calls = 0;
    final chat = _FakeChat(responder: (s, u) async {
      calls++;
      return jsonEncode(<String, dynamic>{
        'units': const [],
        'newCharacters': const [],
      });
    });
    // 预建卡：保证归因前后角色卡不变（指纹稳定），才能验证缓存命中。
    await cast.upsert('n1', '小明', gender: NovelCastGender.male);
    final svc = newService(chat: chat);
    const paragraphs = <String>['小明说：你好。'];

    await svc.attributeChapter(
        novelId: 'n1', chapterId: 'c1', paragraphs: paragraphs);
    expect(calls, 1);

    // 第二次同输入：缓存命中。
    await svc.attributeChapter(
        novelId: 'n1', chapterId: 'c1', paragraphs: paragraphs);
    expect(calls, 1);

    // 音色绑定变化：不影响归因身份，不应重新请求。
    await cast.upsert('n1', '小明', httpVoiceId: 'xm');
    await svc.attributeChapter(
        novelId: 'n1', chapterId: 'c1', paragraphs: paragraphs);
    expect(calls, 1);

    // 角色身份变化（别名）→ 指纹失效 → 重新请求。
    await cast.upsert('n1', '小明',
        aliases: const ['明明'], mergeAliases: true);
    await svc.attributeChapter(
        novelId: 'n1', chapterId: 'c1', paragraphs: paragraphs);
    expect(calls, 2);

    // 正文变化 → 指纹失效。
    await svc.attributeChapter(
        novelId: 'n1',
        chapterId: 'c1',
        paragraphs: const <String>['小明说：变了。']);
    expect(calls, 3);
  });

  test('prompt 注入已知角色与待标注句', () async {
    String? capturedUser;
    final chat = _FakeChat(responder: (s, u) async {
      capturedUser = u;
      return jsonEncode(<String, dynamic>{
        'units': const [],
        'newCharacters': const [],
      });
    });
    await cast.upsert('n1', '萧炎',
        aliases: const ['炎哥'], gender: NovelCastGender.male);
    final svc = newService(chat: chat);
    await svc.attributeChapter(
        novelId: 'n1',
        chapterId: 'c1',
        paragraphs: const ['天色渐晚。萧炎说："走。"']);
    expect(capturedUser, isNotNull);
    expect(capturedUser!, contains('萧炎'));
    expect(capturedUser!, contains('炎哥'));
    // 对白句以 id 形式进入待标注列表，且携带前文上下文供归因。
    expect(capturedUser!, contains(RegExp(r'"id":"0-\d+"')));
    expect(capturedUser!, contains('"text":"走。"'));
    expect(capturedUser!, contains('天色渐晚')); // 旁白作为语境注入 before
  });
}
