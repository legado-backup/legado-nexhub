import 'dart:async' show unawaited;

import 'package:flutter/services.dart' show MethodChannel;
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../platform/platform_service.dart';
import '../utils/app_log.dart';
import 'saf_bridge.dart';

/// 导入入口的统一文件夹选择器。
///
/// 传统桌面 / Android 沿用 [pickFolderPath]；鸿蒙 PC 用系统目录选择器，
/// 再把整棵目录树复制进应用沙箱：picker 授权默认非持久，且外部路径无法
/// 交给 dart:io。复制完成后，扫描 / 解析完全复用现有文件系统管线。
class FolderImport {
  const FolderImport._();

  static const MethodChannel _storage = MethodChannel('nexhub/ohos_storage');

  static Future<String?> pick(BuildContext context) async {
    if (!PlatformService.instance.isOHOSPC) {
      return pickFolderPath();
    }
    final _PickedFolder? picked = await _pickOhosFolder();
    if (picked == null || !context.mounted) return null;
    return _copyWithProgress(context, picked);
  }

  static Future<_PickedFolder?> _pickOhosFolder() async {
    try {
      final Map<String, Object?>? raw =
          await _storage.invokeMapMethod<String, Object?>('pickDirectory');
      if (raw == null) return null;
      final String? path = raw['path'] as String?;
      if (path == null || path.isEmpty) return null;
      final String? name = raw['name'] as String?;
      return _PickedFolder(path: path, name: name ?? 'folder');
    } on Object catch (e, st) {
      AppLog.instance.eWithStack('[目录导入] 选择目录失败', e, st);
      return null;
    }
  }

  static Future<String?> _copyWithProgress(
    BuildContext context,
    _PickedFolder picked,
  ) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
    final Future<void> dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(l10n.folderImportCopyProgress),
          content: Row(
            children: <Widget>[
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(l10n.folderImportCopyProgressHint)),
            ],
          ),
        ),
      ),
    );
    try {
      final String? dest = await _storage.invokeMethod<String>(
        'copyDirectoryToImport',
        <String, Object?>{
          'srcPath': picked.path,
          'name': picked.name,
        },
      );
      if (dest == null || dest.isEmpty) {
        throw StateError('copyDirectoryToImport returned empty path');
      }
      return dest;
    } on Object catch (e, st) {
      AppLog.instance.eWithStack('[目录导入] 复制失败 ${picked.path}', e, st);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).folderImportCopyFailed),
          ),
        );
      }
      return null;
    } finally {
      // 原生复制不依赖对话框；页面销毁时对话框路由可能已一并移除，故先判 canPop。
      if (navigator.mounted && navigator.canPop()) {
        navigator.pop();
      }
      unawaited(dialog);
    }
  }
}

class _PickedFolder {
  const _PickedFolder({required this.path, required this.name});

  final String path;
  final String name;
}
