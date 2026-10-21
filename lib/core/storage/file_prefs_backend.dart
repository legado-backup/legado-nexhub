/// 基于独立 JSON 文件的持久化后端（[PrefsBackend] 实现）。
///
/// 用途：单键数据量大的场景（如浏览历史整包 JSON，可达数百 KB）。
/// shared_preferences 底层是「轻量级偏好存储」，对大字符串值的落盘
/// 可靠性/容量在部分平台（鸿蒙 dataPreferences）不受保证且失败静默；
/// 文件直写没有此约束，也便于用户侧直接查看/备份。
///
/// 原子性：先写 `<key>.json.tmp` 再改名覆盖，写一半被杀不会留下损坏数据。
/// 并发：同一键的写入串行执行，避免共用临时文件互相踩（见 [set]）。
/// 错误策略：读失败（含不存在）返回 null；写失败向上抛出由调用方记录。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../comic/models/reader_preferences.dart' show PrefsBackend;

class FilePrefsBackend implements PrefsBackend {
  FilePrefsBackend({String? dirName}) : _dirName = dirName ?? 'prefs_files';

  final String _dirName;

  Directory? _cachedDir;

  /// 每个键的写入队列（见 [set]）。
  final Map<String, Future<void>> _writeQueues = {};

  Future<Directory> _dir() async {
    final cached = _cachedDir;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, _dirName));
    await dir.create(recursive: true);
    _cachedDir = dir;
    return dir;
  }

  /// 键名转安全文件名（`history_v1` 等本就安全，此处兜底特殊字符）。
  static String _safeName(String key) =>
      key.replaceAll(RegExp(r'[^\w.-]'), '_');

  Future<File> _fileFor(String key) async {
    final dir = await _dir();
    return File(p.join(dir.path, '${_safeName(key)}.json'));
  }

  @override
  Future<String?> get(String key) async {
    try {
      final file = await _fileFor(key);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } on Object catch (e) {
      debugPrint('FilePrefsBackend.get($key) failed: $e');
      return null;
    }
  }

  /// 同一键的写入必须串行：并发写共用 `<key>.json.tmp`，交错时先完成者
  /// 会把 tmp 改名走，后完成者 rename 失败且兜底清理会删到已不存在的 tmp；
  /// 串行还保证后调用的快照最后落盘，不会被更旧的快照覆盖。
  @override
  Future<void> set(String key, String value) {
    final prev = _writeQueues[key] ?? Future<void>.value();
    final next = prev.then(
      (_) => _write(key, value),
      // 前一次写入失败不应阻塞后续写入。
      onError: (Object _) => _write(key, value),
    );
    _writeQueues[key] = next;
    return next;
  }

  Future<void> _write(String key, String value) async {
    final file = await _fileFor(key);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(value, flush: true);
    try {
      await tmp.rename(file.path);
    } on Object {
      // 跨设备/占用导致改名失败时退化为直接覆盖。
      await file.writeAsString(value, flush: true);
      try {
        if (await tmp.exists()) await tmp.delete();
      } on Object catch (e) {
        // 数据已落盘，临时文件清不掉不值得让写入失败。
        debugPrint('FilePrefsBackend.set($key) 清理临时文件失败: $e');
      }
    }
  }
}
