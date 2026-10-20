/// 图片写入系统剪贴板的统一入口。
///
/// 鸿蒙上 `super_clipboard` 的底座 `super_native_extensions` 没有原生实现，
/// 改走应用级 ArkTS 通道 `nexhub/clipboard`：把图片解码成 PixelMap 后写入
/// 系统 pasteboard。其余平台仍由 `super_clipboard` 完成真复制。
library;

import 'package:flutter/services.dart';
import 'package:super_clipboard/super_clipboard.dart';

import 'platform_service.dart';

const MethodChannel _ohosClipboardChannel = MethodChannel('nexhub/clipboard');

/// 复制图片到系统剪贴板。
///
/// 返回 `false` 表示当前平台没有剪贴板图片实现，调用方应回退为复制本地
/// 路径；写入失败抛异常，同样由调用方决定降级提示。
Future<bool> copyImageToSystemClipboard({
  required Uint8List bytes,
  required String extension,
}) async {
  if (PlatformService.instance.isOHOS) {
    // 鸿蒙：见 ClipboardPlugin.ets（系统剪贴板图片位是 PixelMap）。
    await _ohosClipboardChannel.invokeMethod<void>(
      'copyImage',
      <String, dynamic>{'bytes': bytes},
    );
    return true;
  }
  SystemClipboard? clipboard;
  try {
    clipboard = SystemClipboard.instance;
  } on Object {
    clipboard = null;
  }
  if (clipboard == null) return false;
  final item = DataWriterItem();
  final ext = extension.toLowerCase();
  if (ext == '.jpg' || ext == '.jpeg') {
    item.add(Formats.jpeg(bytes));
  } else {
    item.add(Formats.png(bytes));
  }
  await clipboard.write(<DataWriterItem>[item]);
  return true;
}
