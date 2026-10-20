// 鸿蒙存储位置选择弹层：短视口（横屏 / 小窗）下内容不应溢出。
//
// 回归背景：弹层未开 isScrollControlled，系统按 9/16 屏高截断；
// 标题 + 两个双行 LocationTile 的自然高度超出该上限，横屏截图入口
// 打开即报 RenderFlex overflow。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/core/platform/ohos_storage_location_sheet.dart';
import 'package:nexhub/core/theme/app_theme.dart';

void main() {
  testWidgets('短视口下弹层不溢出，且可正常选择应用私有目录', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(640, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    String? picked = 'unset';
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => Center(
              child: TextButton(
                onPressed: () async {
                  picked = await showOhosStorageLocationSheet(
                    ctx,
                    title: '截图保存位置',
                    appPrivateLabel: '应用私有目录',
                    appPrivateHint: '默认路径',
                    systemLabel: '系统「下载」',
                    systemHint: 'Download/nexhub/Screenshots',
                    appendSubdir: 'Screenshots',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.tap(find.text('应用私有目录'));
    await tester.pumpAndSettle();
    expect(picked, '');
  });
}
