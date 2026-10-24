// 鸿蒙状态栏点按回顶设置单测：
// - 默认开启；旧版本 JSON（无该字段）回落开启；
// - toJson / fromJson 往返；
// - Store setter 持久化并在新实例重载后保持。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart'
    show InMemoryBackend;
import 'package:nexhub/core/settings/general_settings.dart';

void main() {
  group('GeneralSettings.statusBarTapToTop', () {
    test('defaults to true', () {
      expect(const GeneralSettings().statusBarTapToTop, isTrue);
    });

    test('missing field in old json falls back to true', () {
      final GeneralSettings s = GeneralSettings.fromJson(<String, dynamic>{});
      expect(s.statusBarTapToTop, isTrue);
    });

    test('json round-trip preserves false', () {
      const GeneralSettings s = GeneralSettings(statusBarTapToTop: false);
      expect(
        GeneralSettings.fromJson(s.toJson()).statusBarTapToTop,
        isFalse,
      );
    });

    test('copyWith updates value without touching the original', () {
      const GeneralSettings s = GeneralSettings();
      final GeneralSettings next = s.copyWith(statusBarTapToTop: false);
      expect(next.statusBarTapToTop, isFalse);
      expect(s.statusBarTapToTop, isTrue);
    });
  });

  group('GeneralSettingsStore.setStatusBarTapToTop', () {
    test('persists and survives reload', () async {
      final InMemoryBackend backend = InMemoryBackend();
      final GeneralSettingsStore store =
          GeneralSettingsStore(backend: backend);
      await store.load();

      await store.setStatusBarTapToTop(false);
      expect(store.statusBarTapToTop, isFalse);

      final GeneralSettingsStore reloaded =
          GeneralSettingsStore(backend: backend);
      final GeneralSettings settings = await reloaded.load();
      expect(settings.statusBarTapToTop, isFalse);
    });

    test('notifies listeners on change', () async {
      final GeneralSettingsStore store =
          GeneralSettingsStore(backend: InMemoryBackend());
      await store.load();

      int notifications = 0;
      store.addListener(() => notifications++);
      await store.setStatusBarTapToTop(false);

      expect(notifications, greaterThan(0));
    });
  });
}
