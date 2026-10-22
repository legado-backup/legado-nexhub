import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late GlossaryManager manager;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nexhub_glossary_p2');
    Hive.init(tempDir.path);
    manager = GlossaryManager();
  });

  tearDown(() async {
    for (final name in <String>[
      GlossaryManager.boxName,
      GlossaryManager.conflictBoxName,
      GlossaryManager.metaBoxName,
    ]) {
      if (Hive.isBoxOpen(name)) {
        await Hive.deleteBoxFromDisk(name);
      }
    }
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // 清理失败忽略。
    }
  });

  test('自动提取新词入库：类型、首现章节与版本号更新', () async {
    final before = await manager.glossaryRevision('book1', '中文');
    final summary = await manager.upsertExtracted(
      'book1',
      '中文',
      const <GlossaryEntry>[
        GlossaryEntry(
          id: '',
          term: 'アリス',
          preferred: '爱丽丝',
          type: 'person',
        ),
        GlossaryEntry(id: '', term: '魔法', preferred: '法术'),
      ],
      chapterId: 'c1',
      chapterTitle: '第一章',
      chapterIndex: 3,
    );
    expect(summary.inserted, 2);
    expect(summary.conflicts, 0);

    final entries = await manager.entriesFor('book1', '中文');
    expect(entries, hasLength(2));
    final alice = entries.firstWhere((e) => e.term == 'アリス');
    expect(alice.preferred, '爱丽丝');
    expect(alice.type, 'person');
    expect(alice.firstChapter, 3);
    final after = await manager.glossaryRevision('book1', '中文');
    expect(after, isNot(before));
  });

  test('同译合并别名，不覆盖既定译名', () async {
    await manager.upsertExtracted(
      'book1',
      '中文',
      const <GlossaryEntry>[
        GlossaryEntry(id: '', term: 'アリス', preferred: '爱丽丝'),
      ],
    );
    final summary = await manager.upsertExtracted(
      'book1',
      '中文',
      const <GlossaryEntry>[
        GlossaryEntry(
          id: '',
          term: 'アリス',
          preferred: '爱丽丝',
          aliases: <String>['艾莉丝'],
          type: 'person',
        ),
      ],
    );
    expect(summary.inserted, 0);
    expect(summary.merged, 1);
    final entry =
        (await manager.entriesFor('book1', '中文')).single;
    expect(entry.preferred, '爱丽丝');
    expect(entry.aliases, contains('艾莉丝'));
    expect(entry.type, 'person');
  });

  test('异译只记冲突并标记状态，绝不覆盖已定译名', () async {
    await manager.upsertExtracted(
      'book1',
      '中文',
      const <GlossaryEntry>[
        GlossaryEntry(id: '', term: 'アリス', preferred: '爱丽丝'),
      ],
    );
    final rev = await manager.glossaryRevision('book1', '中文');
    final summary = await manager.upsertExtracted(
      'book1',
      '中文',
      const <GlossaryEntry>[
        GlossaryEntry(id: '', term: 'アリス', preferred: '艾丽丝'),
      ],
      chapterTitle: '第二章',
    );
    expect(summary.inserted, 0);
    expect(summary.merged, 0);
    expect(summary.conflicts, 1);

    final entry = (await manager.entriesFor('book1', '中文')).single;
    expect(entry.preferred, '爱丽丝');
    expect(entry.status, GlossaryEntry.statusConflict);

    final conflicts =
        await manager.openConflicts(workId: 'book1', lang: '中文');
    expect(conflicts, hasLength(1));
    expect(conflicts.single.existingPreferred, '爱丽丝');
    expect(conflicts.single.proposed, '艾丽丝');
    expect(conflicts.single.chapterTitle, '第二章');
    // 冲突记录本身不改变提示词术语表，版本号不变。
    expect(await manager.glossaryRevision('book1', '中文'), rev);
  });

  test('同一术语多次异译只保留一条冲突，刷新本次译法', () async {
    await manager.upsertExtracted(
      'book1',
      '中文',
      const <GlossaryEntry>[
        GlossaryEntry(id: '', term: 'アリス', preferred: '爱丽丝'),
      ],
    );
    await manager.upsertExtracted(
      'book1',
      '中文',
      const <GlossaryEntry>[
        GlossaryEntry(id: '', term: 'アリス', preferred: '艾丽丝'),
      ],
    );
    await manager.upsertExtracted(
      'book1',
      '中文',
      const <GlossaryEntry>[
        GlossaryEntry(id: '', term: 'アリス', preferred: '阿丽丝'),
      ],
      chapterTitle: '第三章',
    );
    final conflicts = await manager.openConflicts(workId: 'book1');
    expect(conflicts, hasLength(1));
    expect(conflicts.single.existingPreferred, '爱丽丝');
    expect(conflicts.single.proposed, '阿丽丝');
    expect(conflicts.single.chapterTitle, '第三章');
  });

  test('全局术语异译：裁决前不建作品副本，采用后写作品覆盖', () async {
    await manager.saveEntry(
      GlossaryManager.globalWorkId,
      '中文',
      const GlossaryEntry(id: 'g1', term: '魔女', preferred: '魔女'),
    );
    final summary = await manager.upsertExtracted(
      'book1',
      '中文',
      const <GlossaryEntry>[
        GlossaryEntry(id: '', term: '魔女', preferred: '女巫', type: 'person'),
      ],
    );
    expect(summary.inserted, 0);
    expect(summary.conflicts, 1);
    expect(await manager.entriesFor('book1', '中文'), isEmpty);

    final conflict =
        (await manager.openConflicts(workId: 'book1')).single;
    final resolved = await manager.resolveConflict(
      conflict.id,
      GlossaryConflictChoice.proposed,
    );
    expect(resolved.inserted, 1);

    final work = await manager.entriesFor('book1', '中文');
    expect(work.single.term, '魔女');
    expect(work.single.preferred, '女巫');
    expect(work.single.type, 'person');
    final effective = await manager.effectiveEntries('book1', '中文');
    expect(effective.single.preferred, '女巫');
    expect(await manager.openConflicts(workId: 'book1'), isEmpty);
    // 其他作品仍用全局译名。
    expect(
      (await manager.effectiveEntries('book2', '中文')).single.preferred,
      '魔女',
    );
  });

  test('保留原译名：清除冲突状态、不改变版本号', () async {
    await manager.upsertExtracted(
      'book1',
      '中文',
      const <GlossaryEntry>[
        GlossaryEntry(id: '', term: 'アリス', preferred: '爱丽丝'),
      ],
    );
    await manager.upsertExtracted(
      'book1',
      '中文',
      const <GlossaryEntry>[
        GlossaryEntry(id: '', term: 'アリス', preferred: '艾丽丝'),
      ],
    );
    final rev = await manager.glossaryRevision('book1', '中文');
    final conflict =
        (await manager.openConflicts(workId: 'book1')).single;
    await manager.resolveConflict(
      conflict.id,
      GlossaryConflictChoice.existing,
    );

    final entry = (await manager.entriesFor('book1', '中文')).single;
    expect(entry.preferred, '爱丽丝');
    expect(entry.status, GlossaryEntry.statusOk);
    expect(await manager.glossaryRevision('book1', '中文'), rev);
    expect(await manager.openConflicts(workId: 'book1'), isEmpty);
  });

  test('版本指纹区分全局与作品级写入', () async {
    final base = await manager.glossaryRevision('book1', '中文');
    await manager.saveEntry(
      GlossaryManager.globalWorkId,
      '中文',
      const GlossaryEntry(id: 'g1', term: '王都', preferred: '王都'),
    );
    final globalChanged = await manager.glossaryRevision('book1', '中文');
    expect(globalChanged, isNot(base));
    // 未改作品级时，其他作品的指纹同样只含全局变化。
    expect(
      await manager.glossaryRevision('book2', '中文'),
      globalChanged,
    );
    await manager.saveEntry(
      'book1',
      '中文',
      const GlossaryEntry(id: 'w1', term: '王都', preferred: '首都'),
    );
    final workChanged = await manager.glossaryRevision('book1', '中文');
    expect(workChanged, isNot(globalChanged));
    expect(
      await manager.glossaryRevision('book2', '中文'),
      globalChanged,
    );
  });
}
