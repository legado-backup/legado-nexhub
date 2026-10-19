import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/ai/translation_language.dart';

void main() {
  test('常见目标语言映射到 Bing 语言码', () {
    expect(TranslationLanguage.bingCode('中文'), 'zh-Hans');
    expect(TranslationLanguage.bingCode('简体中文'), 'zh-Hans');
    expect(TranslationLanguage.bingCode('繁體中文'), 'zh-Hant');
    expect(TranslationLanguage.bingCode('English'), 'en');
    expect(TranslationLanguage.bingCode('日语'), 'ja');
    expect(TranslationLanguage.bingCode('한국어'), 'ko');
    expect(TranslationLanguage.bingCode('zh-TW'), 'zh-Hant');
    expect(TranslationLanguage.bingCode('fr'), 'fr');
    expect(TranslationLanguage.bingCode('未知语言'), isNull);
  });

  test('界面 Locale 映射', () {
    expect(TranslationLanguage.preferredCodeForLocale(const Locale('zh')),
        'zh-Hans');
    expect(
      TranslationLanguage.preferredCodeForLocale(const Locale('zh', 'TW')),
      'zh-Hant',
    );
    expect(TranslationLanguage.preferredCodeForLocale(const Locale('en')), 'en');
    expect(TranslationLanguage.preferredCodeForLocale(const Locale('ja')), 'ja');
  });

  test('同语言启发式跳过', () {
    expect(TranslationLanguage.shouldTranslate('这是中文标题', '中文'), isFalse);
    expect(TranslationLanguage.shouldTranslate('これは日本語です', '中文'), isTrue);
    expect(TranslationLanguage.shouldTranslate('これは日本語です', '日语'), isFalse);
    expect(TranslationLanguage.shouldTranslate('안녕하세요', '韩语'), isFalse);
    expect(
      TranslationLanguage.shouldTranslate(
          'Hello world, this is a test', 'English'),
      isFalse,
    );
    expect(
      TranslationLanguage.shouldTranslate(
          'Hello world, this is a test', '中文'),
      isTrue,
    );
    expect(TranslationLanguage.shouldTranslate('Привет мир', '俄语'), isFalse);
    expect(TranslationLanguage.shouldTranslate('مرحبا بالعالم', '阿拉伯语'), isFalse);
    expect(TranslationLanguage.shouldTranslate('สวัสดีชาวโลก', '泰语'), isFalse);
  });

  test('纯数字 / URL / 空串不翻译', () {
    expect(TranslationLanguage.shouldTranslate('12345', '中文'), isFalse);
    expect(
      TranslationLanguage.shouldTranslate('https://example.com/a', '中文'),
      isFalse,
    );
    expect(TranslationLanguage.shouldTranslate('   ', '中文'), isFalse);
  });

  test('可读语言名用于 AI 提示词', () {
    expect(TranslationLanguage.readableName('zh-Hans'), '中文（简体）');
    expect(TranslationLanguage.readableName('en'), '英文');
  });
}
