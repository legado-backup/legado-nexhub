import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/core/ai/translation_feature_flags.dart';
import 'package:nexhub/core/widgets/translatable_text.dart';
import 'package:nexhub/generated/app_localizations.dart';
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
    // Chip 不再用 Tooltip 包裹（Tooltip 长按会与翻译长按抢手势）。
    expect(find.byType(Tooltip), findsNothing);
  });

  // 回归：真机手指按住的自然抖动（> 默认 kTouchSlop 18px）会把标准长按
  // 手势在手势竞技场取消，表现为「长按毫无反应」。组件改用 40px 大容忍
  // 识别器后，30px 抖动内长按仍应到达处理函数（中文文本 → 无需翻译提示）。
  testWidgets('长按期间抖动 30px 仍触发长按处理（大容忍识别器）', (tester) async {
    await resetFlags(<String, Object>{
      'translation_bing_enabled_v1': false,
    });
    // 中文 locale + l10n 委托：目标语言为 zh-Hans，中文文本走「无需翻译」
    // 分支（SnackBar 反馈），不发起真实翻译请求。
    await tester.pumpWidget(const MaterialApp(
      locale: Locale('zh'),
      localizationsDelegates: <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: <Locale>[Locale('zh'), Locale('en')],
      home: Scaffold(body: AutoTranslatedText(text: '这是中文标题')),
    ));
    await tester.pumpAndSettle();

    final gesture =
        await tester.startGesture(tester.getCenter(find.text('这是中文标题')));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pump();

    expect(find.text('该内容已是目标语言，无需翻译'), findsOneWidget);
  });
}
