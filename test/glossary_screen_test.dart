/// 作品术语表页：冲突裁决卡展示与采用 / 保留两条闭环。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/features/settings/presentation/translation_glossary_screen.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        ...AppLocalizations.localizationsDelegates,
        ...GlobalMaterialLocalizations.delegates,
      ],
      home: child,
    );

/// 内存版管理器：避免 widget 测试里真实 Hive I/O 与假时钟互相等待。
class _FakeGlossaryManager extends GlossaryManager {
  _FakeGlossaryManager() {
    entries = <GlossaryEntry>[
      const GlossaryEntry(
        id: 'g1',
        term: '魔女',
        preferred: '女巫',
        type: 'person',
        status: GlossaryEntry.statusConflict,
      ),
    ];
    conflicts = <GlossaryConflict>[
      GlossaryConflict(
        id: GlossaryConflict.idFor('book1', '中文', '魔女'),
        workId: 'book1',
        lang: '中文',
        term: '魔女',
        existingPreferred: '女巫',
        proposed: '魔女',
        type: 'person',
        chapterTitle: '第一章',
        createdAt: 1,
      ),
    ];
  }

  late List<GlossaryEntry> entries;
  late List<GlossaryConflict> conflicts;

  @override
  Future<List<GlossaryEntry>> entriesFor(String workId, String lang) async =>
      entries;

  @override
  Future<List<GlossaryEntry>> effectiveEntries(String? workId, String lang) async =>
      entries;

  @override
  Future<List<GlossaryConflict>> openConflicts({
    String? workId,
    String? lang,
  }) async =>
      conflicts;

  @override
  Future<GlossaryUpsertSummary> resolveConflict(
    String id,
    GlossaryConflictChoice choice,
  ) async {
    final conflict = conflicts.singleWhere((c) => c.id == id);
    conflicts = const <GlossaryConflict>[];
    final preferred = choice == GlossaryConflictChoice.proposed
        ? conflict.proposed
        : conflict.existingPreferred;
    entries = <GlossaryEntry>[
      entries.single.copyWith(
        preferred: preferred,
        status: GlossaryEntry.statusOk,
      ),
    ];
    return const GlossaryUpsertSummary(merged: 1);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('冲突卡展示双方译名与章节，采用新译法写回条目', (tester) async {
    final manager = _FakeGlossaryManager();
    await tester.pumpWidget(_wrap(
      TranslationGlossaryScreen(workId: 'book1', manager: manager),
    ));
    await tester.pumpAndSettle();

    expect(find.text('待裁决术语冲突（1）'), findsOneWidget);
    expect(find.text('既有译名：女巫'), findsOneWidget);
    expect(find.text('本次译法：魔女'), findsOneWidget);
    expect(find.text('出自：第一章'), findsOneWidget);

    await tester.tap(find.text('采用新译法'));
    await tester.pumpAndSettle();

    expect(find.text('冲突已裁决'), findsOneWidget);
    expect(find.textContaining('待裁决术语冲突'), findsNothing);
    expect(find.text('魔女 → 魔女'), findsOneWidget);
    expect(manager.entries.single.preferred, '魔女');
    expect(manager.entries.single.status, GlossaryEntry.statusOk);
    expect(manager.conflicts, isEmpty);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('保留原译名清除冲突状态且不改写既定译名', (tester) async {
    final manager = _FakeGlossaryManager();
    await tester.pumpWidget(_wrap(
      TranslationGlossaryScreen(workId: 'book1', manager: manager),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保留原译名'));
    await tester.pumpAndSettle();

    expect(find.text('冲突已裁决'), findsOneWidget);
    expect(find.textContaining('待裁决术语冲突'), findsNothing);
    expect(find.text('魔女 → 女巫'), findsOneWidget);
    expect(manager.entries.single.preferred, '女巫');
    expect(manager.entries.single.status, GlossaryEntry.statusOk);
    expect(manager.conflicts, isEmpty);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
