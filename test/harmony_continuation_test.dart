import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/platform/harmony_continuation.dart';

void main() {
  group('HarmonyContinuation owners', () {
    test('无持有者时快照为 null', () {
      expect(HarmonyContinuation.currentSnapshotJson(), isNull);
    });

    test('attach 后快照带版本号与内容', () {
      final Object token = HarmonyContinuation.attach(
        () => <String, Object?>{'type': 'comic', 'contentId': 'm1'},
      );
      final Map<String, dynamic> data =
          jsonDecode(HarmonyContinuation.currentSnapshotJson()!)
              as Map<String, dynamic>;
      expect(data['v'], 1);
      expect(data['type'], 'comic');
      expect(data['contentId'], 'm1');
      HarmonyContinuation.detach(token);
      expect(HarmonyContinuation.currentSnapshotJson(), isNull);
    });

    test('后注册者优先（栈顶页面覆盖栈底）', () {
      final Object bottom = HarmonyContinuation.attach(
        () => <String, Object?>{'type': 'comic'},
      );
      final Object top = HarmonyContinuation.attach(
        () => <String, Object?>{'type': 'video'},
      );
      expect(
        (jsonDecode(HarmonyContinuation.currentSnapshotJson()!)
            as Map<String, dynamic>)['type'],
        'video',
      );
      HarmonyContinuation.detach(top);
      expect(
        (jsonDecode(HarmonyContinuation.currentSnapshotJson()!)
            as Map<String, dynamic>)['type'],
        'comic',
      );
      HarmonyContinuation.detach(bottom);
      expect(HarmonyContinuation.currentSnapshotJson(), isNull);
    });

    test('跳过返回 null 或抛错的持有者', () {
      final Object providerNull = HarmonyContinuation.attach(() => null);
      final Object providerThrow = HarmonyContinuation.attach(() {
        throw StateError('boom');
      });
      final Object providerValid = HarmonyContinuation.attach(
        () => <String, Object?>{'type': 'novel'},
      );
      HarmonyContinuation.detach(providerValid);
      expect(HarmonyContinuation.currentSnapshotJson(), isNull);
      HarmonyContinuation.detach(providerThrow);
      HarmonyContinuation.detach(providerNull);
    });

    test('detach 未知 token 不影响已有持有者', () {
      final Object token = HarmonyContinuation.attach(
        () => <String, Object?>{'type': 'comic'},
      );
      HarmonyContinuation.detach(Object());
      expect(HarmonyContinuation.currentSnapshotJson(), isNotNull);
      HarmonyContinuation.detach(token);
    });
  });

  group('HarmonyContinuation.encodeChapterWindow', () {
    List<Episode> episodes(int count) => <Episode>[
          for (int i = 0; i < count; i++)
            Episode(id: 'c$i', title: '第${i + 1}话', url: '/c$i'),
        ];

    test('以当前章为中心截取并返回窗口起点', () {
      final ({List<Map<String, dynamic>> items, int start})? window =
          HarmonyContinuation.encodeChapterWindow(episodes(200), 100);
      expect(window, isNotNull);
      expect(window!.start, 60);
      expect(window.items.length, 81);
      expect(window.items.first['id'], 'c60');
      expect(window.items.last['id'], 'c140');
    });

    test('章节不足时返回全量且起点为 0', () {
      final ({List<Map<String, dynamic>> items, int start})? window =
          HarmonyContinuation.encodeChapterWindow(episodes(5), 2);
      expect(window!.start, 0);
      expect(window.items.length, 5);
    });

    test('当前章越界时夹取到有效范围', () {
      final ({List<Map<String, dynamic>> items, int start})? window =
          HarmonyContinuation.encodeChapterWindow(episodes(200), 999);
      expect(window!.items.last['id'], 'c199');
      // center 夹取到 199，窗口起点 = 199 - 40 = 159。
      expect(window.start, 159);
      expect(window.items.length, 41);
    });

    test('空章节返回 null', () {
      expect(HarmonyContinuation.encodeChapterWindow(const <Episode>[], 0),
          isNull);
      expect(HarmonyContinuation.encodeChapterWindow(null, 0), isNull);
    });

    test('超长标题时收缩窗口到字节上限内且保留当前章', () {
      final List<Episode> long = <Episode>[
        for (int i = 0; i < 200; i++)
          Episode(
            id: 'c$i',
            title: '第${i + 1}话 ${'很长的标题' * 120}',
            url: '/c$i?token=${'x' * 200}',
          ),
      ];
      final ({List<Map<String, dynamic>> items, int start})? window =
          HarmonyContinuation.encodeChapterWindow(long, 100);
      expect(window, isNotNull);
      expect(jsonEncode(window!.items).length, lessThanOrEqualTo(48 * 1024));
      expect(
        window.items.any((Map<String, dynamic> item) => item['id'] == 'c100'),
        isTrue,
      );
      expect(window.start + window.items.length, greaterThan(100));
    });
  });
}
