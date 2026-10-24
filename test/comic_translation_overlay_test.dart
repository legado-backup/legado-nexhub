/// 漫画翻译覆盖层展示测试：
/// - 只渲染译文，未译条目不再冒充原文；
/// - 部分翻译显示徽标并可点击重试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart';
import 'package:nexhub/core/comic/comic_translation_manager.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/features/manga/presentation/comic_translation_controller.dart';
import 'package:nexhub/features/manga/presentation/comic_translation_overlay.dart';
import 'package:nexhub/generated/app_localizations.dart';

Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      home: Scaffold(
        body: SizedBox(
          width: 300,
          height: 300,
          child: Stack(children: <Widget>[child]),
        ),
      ),
    );

ComicPageTranslationState _state({
  required ComicTranslationStatus status,
  required List<VisionTextSegment> segments,
}) =>
    ComicPageTranslationState(
      status: ComicPageTranslationStatus.done,
      naturalSize: const Size(1000, 1000),
      data: ComicPageTranslation(
        imageUrl: 'https://img/1.jpg',
        lang: 'zh',
        segments: segments,
        updatedAt: 1,
        status: status,
      ),
    );

VisionTextSegment _seg(String text, String translation, int y) =>
    VisionTextSegment(
      x1: 100,
      y1: y,
      x2: 500,
      y2: y + 200,
      text: text,
      translation: translation,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('只渲染译文，未译区域不显示原文', (WidgetTester tester) async {
    await tester.pumpWidget(_host(ComicTranslationOverlay(
      state: _state(
        status: ComicTranslationStatus.complete,
        segments: <VisionTextSegment>[
          _seg('原文甲', '', 100),
          _seg('原文乙', '译文乙', 400),
        ],
      ),
      zoom: ReaderInitialZoom.fitWidth,
    )));
    expect(find.text('译文乙'), findsOneWidget);
    expect(find.text('原文甲'), findsNothing);
    expect(find.text('原文乙'), findsNothing);
  });

  testWidgets('部分翻译显示徽标，点击重试触发回调', (WidgetTester tester) async {
    var retried = false;
    await tester.pumpWidget(_host(ComicTranslationOverlay(
      state: _state(
        status: ComicTranslationStatus.partial,
        segments: <VisionTextSegment>[
          _seg('原文甲', '译文甲', 100),
          _seg('原文乙', '', 400),
        ],
      ),
      zoom: ReaderInitialZoom.fitWidth,
      onRetry: () => retried = true,
    )));
    expect(find.text('部分翻译'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pump();
    expect(retried, isTrue);
  });
}
