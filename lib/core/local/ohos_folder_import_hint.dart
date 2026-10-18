/// 鸿蒙「文件夹导入不可用」降级提示行。
///
/// 鸿蒙的文件选择插件把目录当文件读取，目录选择接口不可用。凡提供
/// 文件夹导入入口的页面，鸿蒙以本提示行替换入口按钮（与 onboarding
/// 下载目录提示同款样式），引导改用「选择文件」路径。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/generated/app_localizations.dart';

/// 鸿蒙专用的文件夹导入降级提示行。
class OhosFolderImportHint extends StatelessWidget {
  const OhosFolderImportHint({super.key, required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceMd,
        vertical: AppTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.folder_off_rounded,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppTokens.spaceSm),
          Expanded(
            child: Text(
              l10n.folderImportOhosUnsupported,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
