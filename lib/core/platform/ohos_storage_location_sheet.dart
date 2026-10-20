/// 鸿蒙存储位置选择弹窗：应用私有目录 vs 系统「下载」目录。
///
/// 鸿蒙手机不支持任意文件夹选择（FolderSelection 仅 2in1），可写的用户可见
/// 位置只有系统授权的 `Download/<bundleName>`。本弹窗统一下载设置、引导页与
/// 截图路径的入口，返回：
/// - `''`：应用私有目录（默认）；
/// - 非空：系统目录编码路径（首次选择会拉起一次系统授权）；
/// - null：用户取消 / 授权失败。
library;

import 'package:material_ui/material_ui.dart';

import '../theme/app_tokens.dart';
import '../utils/app_log.dart';
import 'ohos_public_storage.dart';

Future<String?> showOhosStorageLocationSheet(
  BuildContext context, {
  required String title,
  required String appPrivateLabel,
  required String appPrivateHint,
  required String systemLabel,
  required String systemHint,
  bool systemSelected = false,
  String? appendSubdir,
}) async {
  final bool? pickSystem = await showModalBottomSheet<bool>(
    context: context,
    // 默认弹层最高 9/16 屏高，横屏 / 小窗放不下两个双行选项，会直接溢出。
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (BuildContext ctx) {
      final ColorScheme scheme = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.spaceLg,
                  0,
                  AppTokens.spaceLg,
                  AppTokens.spaceSm,
                ),
                child: Text(
                  title,
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              _LocationTile(
                selected: !systemSelected,
                title: appPrivateLabel,
                subtitle: appPrivateHint,
                onTap: () => Navigator.of(ctx).pop(false),
              ),
              _LocationTile(
                selected: systemSelected,
                title: systemLabel,
                subtitle: systemHint,
                onTap: () => Navigator.of(ctx).pop(true),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              Divider(height: 1, color: scheme.outlineVariant),
            ],
          ),
        ),
      );
    },
  );
  if (pickSystem == null) return null;
  if (!pickSystem) return '';
  try {
    final String? root = await OhosPublicStorage.requestRoot();
    if (root == null) return null;
    if (appendSubdir == null || appendSubdir.isEmpty) return root;
    final String dir = ohosDocJoin(root, appendSubdir);
    await OhosPublicStorage.mkdir(ohosDocToPlainPath(dir));
    return dir;
  } on Object catch (e) {
    AppLog.instance.w('[鸿蒙存储位置] 系统目录授权失败: $e');
    return null;
  }
}

class _LocationTile extends StatelessWidget {
  const _LocationTile({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        selected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_unchecked_rounded,
        color: selected ? scheme.primary : scheme.outline,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: onTap,
    );
  }
}
