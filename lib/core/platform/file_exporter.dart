/// 导出文件到用户可见位置的统一入口。
///
/// 鸿蒙：应用级 ArkTS 通道 `nexhub/file_export`（DocumentViewPicker 系统
/// 「另存为」对话框）。此前导出走「写沙箱 + share_plus 系统分享」，分享
/// 链路在真机不可靠；改为用户直接选择保存位置后写入字节。
///
/// 其它平台仍由调用方走各自的目录选择 / 分享逻辑，不经过本类。
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import '../utils/app_log.dart';

class FileExporter {
  FileExporter._();

  static const MethodChannel _channel = MethodChannel('nexhub/file_export');

  /// 打开系统「另存为」对话框并写入文本内容。
  ///
  /// 返回保存后的 URI；用户取消返回 null。原生失败抛 [PlatformException]。
  static Future<String?> saveTextFile({
    required String fileName,
    required String content,
  }) {
    return saveBytes(
      fileName: fileName,
      bytes: utf8.encode(content),
    );
  }

  /// 打开系统「另存为」对话框并写入字节。
  ///
  /// 返回保存后的 URI；用户取消返回 null。原生失败抛 [PlatformException]。
  static Future<String?> saveBytes({
    required String fileName,
    required Uint8List bytes,
  }) async {
    try {
      final String? saved = await _channel.invokeMethod<String>(
        'saveFile',
        <String, dynamic>{
          'fileName': fileName,
          'bytes': bytes,
        },
      );
      if (saved == null || saved.isEmpty) return null;
      return saved;
    } on PlatformException catch (e) {
      AppLog.instance.w('[导出] 原生保存通道失败: ${e.code} ${e.message}');
      rethrow;
    }
  }
}
