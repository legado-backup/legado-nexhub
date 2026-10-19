import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/core/ai/translation_feature_flags.dart';
import 'package:nexhub/core/widgets/translatable_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> resetFlags(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    await TranslationFeatureFlags.instance.reload();
  }

  testWidgets('关闭自动翻译时保留原文，长按触发手动翻译', (tester) async {
    await resetFlags(<String, Object>{
      'translation_auto_title_v1': false,
      'translation_bing_enabled_v1': false,
    });
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: AutoTranslatedText(text: '这是中文标题')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('这是中文标题'), findsOneWidget);
  });

  testWidgets('BilingualTranslatedText 折叠时只显示原文', (tester) async {
    await resetFlags(<String, Object>{
      'translation_bing_enabled_v1': false,
    });
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: BilingualTranslatedText(
          text: '这是中文简介',
          kind: TranslatableTextKind.summary,
          maxLines: 2,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('这是中文简介'), findsOneWidget);
  });

  testWidgets('标签 Chip 在 material_ui 主题树下可渲染', (tester) async {
    await resetFlags(<String, Object>{
      'translation_bing_enabled_v1': false,
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TranslatableTagChip(
          label: '奇幻',
          onPressed: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('奇幻'), findsOneWidget);
  });
}
