import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/ai/text_translation_cache.dart';
import 'package:nexhub/core/ai/translation_engine_policy.dart';
import 'package:nexhub/core/ai/translation_feature_flags.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('引擎优先级：关闭 Bing / 高级选项 / AI 优先都走 AI', () {
    expect(
      TranslationEnginePolicy.order(
          bingEnabled: true, preferBing: true, advancedOptions: false),
      TranslationEngineOrder.bingFirst,
    );
    expect(
      TranslationEnginePolicy.order(
          bingEnabled: false, preferBing: true, advancedOptions: false),
      TranslationEngineOrder.aiFirst,
    );
    expect(
      TranslationEnginePolicy.order(
          bingEnabled: true, preferBing: false, advancedOptions: false),
      TranslationEngineOrder.aiFirst,
    );
    expect(
      TranslationEnginePolicy.order(
          bingEnabled: true, preferBing: true, advancedOptions: true),
      TranslationEngineOrder.aiFirst,
    );
    expect(
      TranslationEnginePolicy.advanced(
          hasGlossary: true, nonStandardStyle: false, cot: false),
      isTrue,
    );
    expect(
      TranslationEnginePolicy.advanced(
          hasGlossary: false, nonStandardStyle: true, cot: false),
      isTrue,
    );
    expect(
      TranslationEnginePolicy.advanced(
          hasGlossary: false, nonStandardStyle: false, cot: true),
      isTrue,
    );
  });

  test('开关默认全开并可持久化', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final flags = TranslationFeatureFlags.instance;
    await flags.reload();
    expect(flags.bingEnabled, isTrue);
    expect(flags.bingFirst, isTrue);
    expect(flags.autoTitle, isTrue);
    expect(flags.autoTags, isTrue);
    expect(flags.autoSummary, isTrue);
    expect(flags.autoComments, isTrue);

    await flags.update(
      bingEnabled: false,
      bingFirst: false,
      autoTitle: false,
      autoComments: false,
    );
    expect(flags.bingEnabled, isFalse);
    expect(flags.bingFirst, isFalse);
    expect(flags.autoTitle, isFalse);
    expect(flags.autoTags, isTrue);
    expect(flags.autoComments, isFalse);

    final again = await SharedPreferences.getInstance();
    expect(again.getBool('translation_bing_enabled_v1'), isFalse);
  });

  test('缓存 key 由目标语言与原文摘要组成', () {
    final a = TextTranslationCache.keyFor('zh-Hans', 'Hello');
    final b = TextTranslationCache.keyFor('zh-Hans', 'Hello');
    final c = TextTranslationCache.keyFor('en', 'Hello');
    expect(a, b);
    expect(a, isNot(c));
    expect(a, startsWith('zh-Hans|'));
  });
}
