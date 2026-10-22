import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/ai/glossary_matcher.dart';

GlossaryEntry _e(
  String term,
  String preferred, {
  List<String> aliases = const <String>[],
  String type = GlossaryEntry.typeTerm,
}) =>
    GlossaryEntry(
      id: term,
      term: term,
      preferred: preferred,
      aliases: aliases,
      type: type,
    );

void main() {
  group('normalize', () {
    test('全角 ASCII 转半角、全角空格转空格、统一小写', () {
      expect(
        GlossaryMatcher.normalize('ＳＡＫＵＲＡ　Ａｎｎ'),
        'sakura ann',
      );
      // 假名/汉字不在全角 ASCII 区间，保持原样。
      expect(GlossaryMatcher.normalize('サクラ桜'), 'サクラ桜');
    });
  });

  group('occursIn', () {
    test('拉丁词条按词边界匹配，避免前缀误命中', () {
      expect(GlossaryMatcher.occursIn('Ann', 'Ann is here'), isTrue);
      expect(GlossaryMatcher.occursIn('Ann', 'Anna is here'), isFalse);
      expect(GlossaryMatcher.occursIn('Ann', '（Ann）'), isTrue);
      // 全角原文 + 日文助词均视作边界。
      expect(GlossaryMatcher.occursIn('Ann', 'ＡＮＮは走った'), isTrue);
    });

    test('CJK 词条按子串匹配', () {
      expect(GlossaryMatcher.occursIn('サクラ', 'サクラは走った'), isTrue);
      expect(GlossaryMatcher.occursIn('桜', '桜の木'), isTrue);
      expect(GlossaryMatcher.occursIn('桜', '梅の木'), isFalse);
    });

    test('空词条不命中', () {
      expect(GlossaryMatcher.occursIn('  ', '任意文本'), isFalse);
    });
  });

  group('entriesInTexts', () {
    test('只保留本批出现的词条并保持原顺序', () {
      final entries = <GlossaryEntry>[
        _e('サクラ', '小樱'),
        _e('怪物', '魔物'),
        _e('Ann', '安'),
      ];
      final picked = GlossaryMatcher.entriesInTexts(
        entries,
        <String>['サクラ与怪物', 'Ann来了'],
      );
      expect(picked.map((e) => e.term), <String>['サクラ', '怪物', 'Ann']);
    });

    test('不出现的词条不注入；空/半空词条跳过', () {
      final picked = GlossaryMatcher.entriesInTexts(
        <GlossaryEntry>[
          _e('無関係', '无关'),
          _e('', '空原文'),
          _e('空译名', ''),
          _e('桜', '樱'),
        ],
        <String>['桜が咲いた'],
      );
      expect(picked.map((e) => e.term), <String>['桜']);
    });

    test('条数与字符双上限', () {
      final entries = <GlossaryEntry>[
        _e('甲', 'A'),
        _e('乙', 'B'),
        _e('丙', 'C'),
      ];
      expect(
        GlossaryMatcher.entriesInTexts(entries, <String>['甲乙丙'],
            maxEntries: 2),
        hasLength(2),
      );
      // 单条成本 = 原词 + 译名；字符预算不足时从该条起停止。
      expect(
        GlossaryMatcher.entriesInTexts(entries, <String>['甲乙丙'],
            maxChars: 3),
        hasLength(1),
      );
    });

    test('纯空白文本不注入任何词条', () {
      expect(
        GlossaryMatcher.entriesInTexts(
          <GlossaryEntry>[_e('桜', '樱')],
          <String>['  ', ''],
        ),
        isEmpty,
      );
    });
  });

  group('词条类型匹配策略', () {
    test('称谓/口癖等只按完整词条匹配，不按别名', () {
      final speech = _e(
        'ですわ',
        '的呢',
        aliases: <String>['わ'],
        type: 'speech',
      );
      expect(GlossaryMatcher.matchSources(speech), <String>['ですわ']);
      expect(GlossaryMatcher.occursIn(speech.term, 'そうですわ'), isTrue);
      final normal = _e('サクラ', '小樱', aliases: <String>['樱']);
      expect(GlossaryMatcher.matchSources(normal), <String>['サクラ', '樱']);
    });
  });

  group('occurrenceCount / recurringEntries', () {
    test('原文与别名重叠出现只计一次', () {
      final entry = _e('サクラ', '小樱', aliases: <String>['サクラさん']);
      // サクラさん 覆盖了 サクラ，合并后仍算 1 次。
      expect(
        GlossaryMatcher.occurrenceCount(
            entry, GlossaryMatcher.normalize('サクラさんが来た')),
        1,
      );
      expect(
        GlossaryMatcher.occurrenceCount(
            entry, GlossaryMatcher.normalize('サクラとサクラさん')),
        2,
      );
    });

    test('按最低频次筛选候选词条', () {
      final entries = <GlossaryEntry>[_e('桜', '樱'), _e('梅', '梅')];
      final recurring = GlossaryMatcher.recurringEntries(
        entries,
        '桜が咲いた。桜は散った。',
        minOccurrences: 2,
      );
      expect(recurring.map((e) => e.term), <String>['桜']);
    });
  });
}
