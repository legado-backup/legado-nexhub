import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/auth/source_auth_manager.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/services/source_library_subscription.dart';
import 'package:nexhub/core/services/source_repository.dart';
import 'package:nexhub/core/theme/app_theme.dart';
import 'package:nexhub/core/widgets/app_segmented_tabs.dart';
import 'package:nexhub/core/widgets/unified_source_tile.dart';
import 'package:nexhub/features/sources/presentation/source_manager_screen.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 源管理页顶部导航与列表卡布局测试（2026-10-04 格式互换 + 整卡收缩）：
/// - 低配整卡模式（sourceDragSplitEffect 默认关）：强调色卡只包住有源的行，
///   末行以下的无源空白回到页面底色（此前被 Expanded/TabBarView 的紧约束
///   撑满视口，shrinkWrap 不生效）；
/// - 第一行「源列表/源库/网络导入/本地导入」= 下划线文字页签，点击切换内容；
/// - 第二行「小说/媒体/漫画」= 胶囊分段，点击切分类；
/// - 空状态「添加源」程序化跳转网络导入页签时内容随之切换。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  PluginConfig novelSource(String id) => PluginConfig.fromJson(<String, dynamic>{
        'id': id,
        'name': '小说源$id',
        'type': 'novelSource',
        'responseType': 'json',
        'site': <String, dynamic>{
          'domain': 'https://example.com/$id',
          'baseUrl': 'https://example.com/$id',
        },
        'parser': <String, dynamic>{'type': 'builtin'},
        'routes': <String, dynamic>{'images': '/images?cid={cid}'},
        'selectors': <String, dynamic>{'images': r'$.images'},
      });

  Future<void> pumpManager(
    WidgetTester tester,
    List<PluginConfig> sources, {
    SourceType? filterType,
    double bottomInset = 0,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SourceRepository>.value(
            value: SourceRepository(sources),
          ),
          ChangeNotifierProvider<SourceLibrarySubscription>.value(
            value: SourceLibrarySubscription(),
          ),
          ChangeNotifierProvider<SourceAuthManager>.value(
            value: SourceAuthManager(
              cookieHeader: (String host) => null,
              cookieVersions: const Stream<int>.empty(),
              clearCookies: (String host) {},
              probe: (String url, {String? referer}) async => '',
            ),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
          // 与 lib/app.dart 同款：GlobalMaterialLocalizations 须经 material_ui
          // 分叉导出（fork 的 MaterialLocalizations 类型），TabBar 的分叉检查
          // 才认账；AppLocalizations.delegate 提供应用自身文案。
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          // 嵌入模式依赖外层外壳的 Scaffold 提供 Material 祖先（网络导入
          // 页的输入框需要），与真实使用场景（LibraryShell）一致。
          home: Builder(
            builder: (BuildContext ctx) => MediaQuery(
              // 模拟主框架 extendBody + 玻璃底栏注入的底部避让量（鸿蒙等
              // 移动端模块内页的真实环境）。
              data: MediaQuery.of(ctx).copyWith(
                padding: EdgeInsets.only(bottom: bottomInset),
              ),
              child: Scaffold(
                body:
                    SourceManagerScreen(embedded: true, filterType: filterType),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 找低配模式那张静态强调色卡（cardContainer 底色的 Material）。
  Material lowSpecCard(WidgetTester tester) {
    final BuildContext rowCtx =
        tester.element(find.text('小说源a').first);
    final Color card = AppTheme.cardContainer(Theme.of(rowCtx).colorScheme);
    return tester
        .widgetList<Material>(
          find.byWidgetPredicate(
            (Widget w) => w is Material && w.color == card,
          ),
        )
        .first;
  }

  testWidgets('低配整卡模式：卡底只包有源行，不再撑满视口', (WidgetTester tester) async {
    await pumpManager(
      tester,
      <PluginConfig>[novelSource('a'), novelSource('b')],
    );
    // 默认测试视口 600 高，两行源 + 上下留白 ≈ 240；旧行为卡被撑满到
    // 可用区底（> 400）。
    expect(tester.getSize(find.byWidget(lowSpecCard(tester))).height,
        lessThan(400));
  });

  testWidgets('低配整卡模式：底栏避让量不涂进卡片，卡底贴最后一行', (WidgetTester tester) async {
    await pumpManager(
      tester,
      <PluginConfig>[novelSource('a'), novelSource('b')],
      bottomInset: 80,
    );
    final Rect cardRect = tester.getRect(find.byWidget(lowSpecCard(tester)));
    final Rect lastRowRect =
        tester.getRect(find.byType(UnifiedSourceTile).last);
    // 卡底只保留设计留白（spaceMd=12）；若把 80px 底栏避让也算进
    // 列表内边距，这段无源区域会被涂成强调色（差值 ≈ 92）。
    expect(cardRect.bottom - lastRowRect.bottom, lessThan(24));
  });

  testWidgets('第一行下划线页签：点击切换内容，分类分段随页签离开', (WidgetTester tester) async {
    await pumpManager(tester, <PluginConfig>[novelSource('a')]);
    expect(find.text('小说源a'), findsOneWidget);
    await tester.tap(find.text('网络导入'));
    await tester.pumpAndSettle();
    expect(find.text('小说源a'), findsNothing);
    expect(find.byWidgetPredicate((Widget w) => w is AppSegmentedTabs),
        findsNothing);
  });

  testWidgets('第二行胶囊分段：点击切分类', (WidgetTester tester) async {
    await pumpManager(tester, <PluginConfig>[novelSource('a')]);
    // 漫画分类为空 → 空状态，小说源不再可见。
    await tester.tap(find.text('漫画'));
    await tester.pumpAndSettle();
    expect(find.text('小说源a'), findsNothing);
  });

  testWidgets('分区源管理（filterType 非空）保留原胶囊分段样式', (WidgetTester tester) async {
    await pumpManager(
      tester,
      <PluginConfig>[novelSource('a')],
      filterType: SourceType.novelSource,
    );
    // 分区页面不出现下划线页签，顶栏仍是原胶囊分段（图标+文字）。
    expect(find.byType(TabBar), findsNothing);
    expect(find.byWidgetPredicate((Widget w) => w is AppSegmentedTabs),
        findsOneWidget);
    expect(find.text('小说源a'), findsOneWidget);
  });

  testWidgets('空态「添加源」程序化跳转网络导入，指示条同步', (WidgetTester tester) async {
    await pumpManager(tester, <PluginConfig>[]);
    await tester.tap(find.text('添加源'));
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((Widget w) => w is AppSegmentedTabs),
        findsNothing);
  });
}
