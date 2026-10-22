/// 翻译缓存指纹：输入不变则稳定，任一影响译文的输入变化则失效；
/// 未在原文出现的术语变化不误报过期。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/ai/prompt_builder.dart';
import 'package:nexhub/core/ai/translation_options_store.dart';
import 'package:nexhub/core/novel/novel_translation_manager.dart';
import 'package:nexhub/features/novel/domain/novel_translation_fingerprint.dart';

const List<String> _sources = <String>['魔女は笑った。', 'アリスは頷いた。'];

const List<GlossaryEntry> _glossary = <GlossaryEntry>[
  GlossaryEntry(id: 'g1', term: '魔女', preferred: '女巫'),
  GlossaryEntry(id: 'g2', term: 'アリス', preferred: '爱丽丝'),
];

class _FakeGlossary extends GlossaryManager {
  _FakeGlossary(this.entries);

  final List<GlossaryEntry> entries;

  @override
  Future<List<GlossaryEntry>> effectiveEntries(String? workId, String lang) async =>
      entries;
}

class _ThrowingGlossary extends GlossaryManager {
  @override
  Future<List<GlossaryEntry>> effectiveEntries(String? workId, String lang) async =>
      throw StateError('glossary unavailable');
}

class _FakeOptions extends TranslationOptionsStore {
  _FakeOptions({
    this.style = TranslationStyle.standard,
    this.cot = false,
    this.refined = false,
  });

  final TranslationStyle style;
  final bool cot;
  final bool refined;

  @override
  Future<TranslationStyle> effectiveStyle(String? workId) async => style;

  @override
  Future<bool> getCotEnabled() async => cot;

  @override
  Future<bool> getRefinedEnabled() async => refined;
}

String _compute({
  List<String> sources = _sources,
  String lang = '中文',
  List<GlossaryEntry> glossary = _glossary,
  TranslationStyle style = TranslationStyle.standard,
  bool cot = false,
}) =>
    NovelTranslationFingerprint.compute(
      sources: sources,
      lang: lang,
      glossary: glossary,
      style: style,
      cot: cot,
    );

void main() {
  test('相同输入的指纹稳定且为 64 位 SHA-256', () {
    final a = _compute();
    final b = _compute();
    expect(a, b);
    expect(a, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('原文变化使指纹失效', () {
    expect(_compute(sources: <String>[..._sources, '追加。']), isNot(_compute()));
  });

  test('目标语言变化使指纹失效', () {
    expect(_compute(lang: 'English'), isNot(_compute()));
  });

  test('原文命中的术语改译使指纹失效', () {
    final changed = <GlossaryEntry>[
      const GlossaryEntry(id: 'g1', term: '魔女', preferred: '魔女'),
      _glossary[1],
    ];
    expect(_compute(glossary: changed), isNot(_compute()));
  });

  test('原文未出现的术语变化不影响指纹', () {
    final extra = <GlossaryEntry>[
      ..._glossary,
      const GlossaryEntry(id: 'g3', term: 'ドラゴン', preferred: '龙'),
    ];
    expect(_compute(glossary: extra), _compute());
  });

  test('术语顺序变化不影响指纹', () {
    expect(_compute(glossary: _glossary.reversed.toList()), _compute());
  });

  test('翻译风格变化使指纹失效', () {
    expect(_compute(style: TranslationStyle.elegant), isNot(_compute()));
  });

  test('CoT 开关变化使指纹失效', () {
    expect(_compute(cot: true), isNot(_compute()));
  });

  test('computeForWork 组装当前术语、风格与 CoT', () async {
    final actual = await NovelTranslationFingerprint.computeForWork(
      workId: 'w1',
      lang: '中文',
      sources: _sources,
      glossaryManager: _FakeGlossary(_glossary),
      options: _FakeOptions(style: TranslationStyle.elegant, cot: true),
    );
    expect(
      actual,
      _compute(style: TranslationStyle.elegant, cot: true),
    );
  });

  test('computeForWork 读取失败返回 null', () async {
    final actual = await NovelTranslationFingerprint.computeForWork(
      workId: 'w1',
      lang: '中文',
      sources: _sources,
      glossaryManager: _ThrowingGlossary(),
      options: _FakeOptions(),
    );
    expect(actual, isNull);
  });

  test('缓存指纹一致不过期，不一致才过期', () async {
    final matching = _compute();
    final stale = await NovelTranslationFingerprint.isStale(
      cachedFingerprint: matching,
      workId: 'w1',
      lang: '中文',
      sources: _sources,
      glossaryManager: _FakeGlossary(_glossary),
      options: _FakeOptions(),
    );
    expect(stale, isFalse);

    final changed = await NovelTranslationFingerprint.isStale(
      cachedFingerprint: 'old-fingerprint',
      workId: 'w1',
      lang: '中文',
      sources: _sources,
      glossaryManager: _FakeGlossary(_glossary),
      options: _FakeOptions(),
    );
    expect(changed, isTrue);
  });

  test('旧缓存无指纹不判定过期', () async {
    final stale = await NovelTranslationFingerprint.isStale(
      cachedFingerprint: null,
      workId: 'w1',
      lang: '中文',
      sources: _sources,
      glossaryManager: _ThrowingGlossary(),
      options: _FakeOptions(),
    );
    expect(stale, isFalse);
  });

  test('指纹读取失败不判定过期', () async {
    final stale = await NovelTranslationFingerprint.isStale(
      cachedFingerprint: 'old-fingerprint',
      workId: 'w1',
      lang: '中文',
      sources: _sources,
      glossaryManager: _ThrowingGlossary(),
      options: _FakeOptions(),
    );
    expect(stale, isFalse);
  });

  test('缓存模型序列化往返保留指纹，旧数据缺省为空', () {
    const t = NovelChapterTranslation(
      novelId: 'n1',
      chapterId: 'c1',
      chapterTitle: '第一章',
      lang: '中文',
      translations: <String>['译文'],
      sources: _sources,
      fingerprint: 'abc123',
      updatedAt: 1,
    );
    final back = NovelChapterTranslation.fromJson(
      jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>,
    );
    expect(back.fingerprint, 'abc123');

    final legacy = NovelChapterTranslation.fromJson(<String, dynamic>{
      'novelId': 'n1',
      'chapterId': 'c1',
      'chapterTitle': '第一章',
      'lang': '中文',
      'translations': <String>['译文'],
      'updatedAt': 1,
    });
    expect(legacy.fingerprint, isNull);
  });

  test('精译开关参与指纹：开启与关闭产生不同指纹', () {
    expect(
      NovelTranslationFingerprint.compute(
        sources: _sources,
        lang: '中文',
        refined: true,
      ),
      isNot(NovelTranslationFingerprint.compute(
        sources: _sources,
        lang: '中文',
      )),
    );
  });

  test('开启精译使旧缓存过期，关闭不影响旧缓存', () async {
    final cached = NovelTranslationFingerprint.compute(
      sources: _sources,
      lang: '中文',
      glossary: _glossary,
    );
    expect(
      await NovelTranslationFingerprint.isStale(
        cachedFingerprint: cached,
        workId: 'w1',
        lang: '中文',
        sources: _sources,
        glossaryManager: _FakeGlossary(_glossary),
        options: _FakeOptions(),
      ),
      isFalse,
    );
    expect(
      await NovelTranslationFingerprint.isStale(
        cachedFingerprint: cached,
        workId: 'w1',
        lang: '中文',
        sources: _sources,
        glossaryManager: _FakeGlossary(_glossary),
        options: _FakeOptions(refined: true),
      ),
      isTrue,
    );
  });
}
