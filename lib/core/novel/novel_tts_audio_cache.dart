/// 在线 TTS 音频文件缓存。
///
/// key = md5(URL 模板 | 音色 | 语速 | 文本)（参考 legado_NG 的音频缓存键
/// 构成：合成输入完全一致才命中）。命中跳过网络请求；写入走「.part 临时
/// 文件 + rename」原子发布，中断不会留下半截音频。
///
/// 目录：应用支持目录 `novel_tts_cache/`（[createDefault]）；测试可注入
/// 任意临时目录。清理由设置页按需调用 [clear]。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class TtsAudioFileCache {
  TtsAudioFileCache(this.directory);

  /// 缓存根目录（不存在时懒创建）。
  final Directory directory;

  /// 默认实例：应用支持目录下 `novel_tts_cache/`。
  static Future<TtsAudioFileCache> createDefault() async {
    final support = await getApplicationSupportDirectory();
    return TtsAudioFileCache(
        Directory('${support.path}${Platform.pathSeparator}novel_tts_cache'));
  }

  /// 计算缓存键（模板/音色/语速/文本任一变化即失效）。
  static String keyFor({
    required String urlTemplate,
    required String voice,
    required String rate,
    required String text,
  }) =>
      md5
          .convert(utf8.encode(<String>[
            urlTemplate,
            voice,
            rate,
            text,
          ].join('\u0000')))
          .toString();

  Future<Directory> _ensureDir() async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  File fileFor(String key) =>
      File('${directory.path}${Platform.pathSeparator}$key.audio');

  /// 读取缓存；未命中/读失败返回 null（坏文件视同未命中，下次覆盖）。
  Future<Uint8List?> read(String key) async {
    try {
      final f = fileFor(key);
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } on Object {
      return null;
    }
  }

  /// 原子写入缓存（.part → rename）。
  Future<void> write(String key, Uint8List bytes) async {
    try {
      final dir = await _ensureDir();
      final target = File('${dir.path}${Platform.pathSeparator}$key.audio');
      if (await target.exists()) return;
      final part = File(
          '${dir.path}${Platform.pathSeparator}$key.audio.${DateTime.now().millisecondsSinceEpoch}.part');
      await part.writeAsBytes(bytes, flush: true);
      try {
        await part.rename(target.path);
      } on FileSystemException {
        // 并发写同 key：目标已存在即视为成功。
        await part.delete().catchError((Object _) => part);
      }
    } on Object {
      // 缓存写失败不影响朗读（网络结果已可用）。
    }
  }

  /// 清空全部缓存（设置页入口）。返回删除的文件数。
  Future<int> clear() async {
    if (!await directory.exists()) return 0;
    var count = 0;
    await for (final entity in directory.list()) {
      if (entity is File) {
        try {
          await entity.delete();
          count++;
        } on Object {
          // 单文件删除失败继续。
        }
      }
    }
    return count;
  }

  /// 缓存文件数与总字节数。
  Future<(int count, int bytes)> stats() async {
    if (!await directory.exists()) return (0, 0);
    var count = 0;
    var bytes = 0;
    await for (final entity in directory.list()) {
      if (entity is File) {
        count++;
        try {
          bytes += await entity.length();
        } on Object {
          // 文件被并发删除时忽略。
        }
      }
    }
    return (count, bytes);
  }
}
