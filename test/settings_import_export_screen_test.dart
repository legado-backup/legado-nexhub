/// 备份导入 / 导出：勾选实时刷新、全选切换、选择器异常降级。
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/services/backup_archive.dart';
import 'package:nexhub/core/widgets/backup_category_selector.dart';
import 'package:nexhub/features/settings/presentation/settings_import_export_screen.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: child),
    );

/// 模拟鸿蒙 file_picker 取消选择时抛出的原生异常。
class _ThrowingFilePicker extends FilePicker {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    throw PlatformException(
      code: 'unknown_activity',
      message: 'Unknown activity error, please fill an issue.',
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('全选按钮在全选时显示「全不选」并可清空', (WidgetTester tester) async {
    Set<BackupCategory> selected =
        Set<BackupCategory>.from(kSelectableBackupCategories);

    await tester.pumpWidget(_wrap(
      StatefulBuilder(
        builder: (context, setState) => BackupCategorySelector(
          selected: selected,
          onChanged: (next) => setState(() => selected = next),
        ),
      ),
    ));

    expect(find.text('全不选'), findsOneWidget);
    expect(find.text('全选'), findsNothing);

    await tester.tap(find.text('全不选'));
    await tester.pump();
    expect(selected, isEmpty);
    expect(find.text('全选'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(selected.length, kSelectableBackupCategories.length);
    expect(find.text('全不选'), findsOneWidget);
  });

  testWidgets('导出弹层勾选实时刷新，全选状态随之切换', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const SettingsImportExportScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pumpAndSettle();

    // 初始全选：提示「全不选」。
    expect(find.text('全不选'), findsOneWidget);

    final sourceTile = find.widgetWithText(CheckboxListTile, '源与订阅');
    expect(tester.widget<CheckboxListTile>(sourceTile).value, isTrue);

    // 取消一类后立即显示为未勾选，且按钮切回「全选」。
    await tester.tap(sourceTile);
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(sourceTile).value, isFalse);
    expect(find.text('全选'), findsOneWidget);

    // 点「全选」恢复全选，按钮切回「全不选」。
    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(sourceTile).value, isTrue);
    expect(find.text('全不选'), findsOneWidget);
  });

  testWidgets('导入选择器抛原生异常时提示失败，不产生未捕获异常', (WidgetTester tester) async {
    final FilePicker original = FilePicker.platform;
    FilePicker.platform = _ThrowingFilePicker();
    addTearDown(() => FilePicker.platform = original);

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const SettingsImportExportScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.file_open_rounded));
    await tester.pumpAndSettle();

    expect(find.text('导入失败'), findsOneWidget);
  });
}
