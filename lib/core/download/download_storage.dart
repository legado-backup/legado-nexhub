/// 下载任务持久化存储（文档 /）。
///
/// 将任务列表序列化为 JSON 存入 PrefsBackend（替代 Hive）。
/// `clear()` 仅清空存储中的任务记录，不删除磁盘文件——
/// 与 `DownloadManager.clearAll(false)` 配合使用后，
/// 管理器立即从 `.meta.json` 恢复孤立记录。
library;

import 'dart:convert';

import '../utils/app_log.dart';
import '../comic/models/reader_preferences.dart';
import '../storage/file_prefs_backend.dart';
import 'download_task.dart';

/// 下载任务存储（可注入后端，测试用 InMemoryBackend）。
class DownloadStorage {
  static const String _key = 'download_tasks';

  final PrefsBackend _backend;

  DownloadStorage({PrefsBackend? backend})
      // 默认走独立文件存储：任务整列表 JSON 随下载量增长，shared_preferences
      // 底层「轻量级偏好存储」在鸿蒙对大字符串值落盘不可靠且失败静默。
      : _backend = backend ?? FilePrefsBackend();

  /// 读取全部任务。
  Future<List<DownloadTask>> loadAll() async {
    String? raw = await _backend.get(_key);
    if (raw == null && _backend is FilePrefsBackend) {
      // 一次性迁移：旧版本任务记录存于 shared_preferences，文件后端不存在
      // 而旧值还在时搬过来，之后以文件为准（旧键保留不动，作兜底）。
      try {
        final legacy = await const SharedPrefsBackend().get(_key);
        if (legacy != null && legacy.isNotEmpty) {
          await _backend.set(_key, legacy);
          AppLog.instance
              .i('[下载] 任务记录已从偏好存储迁移到独立文件（${legacy.length} 字节）');
          raw = legacy;
        }
      } on Object catch (e) {
        AppLog.instance.w('[下载] 迁移旧偏好存储失败: $e');
      }
    }
    if (raw == null || raw.isEmpty) return <DownloadTask>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => DownloadTask.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return <DownloadTask>[];
    }
  }

  /// 保存全部任务（全量覆盖）。
  Future<void> saveAll(List<DownloadTask> tasks) async {
    final raw = jsonEncode(tasks.map((t) => t.toJson()).toList());
    await _backend.set(_key, raw);
  }

  /// 清空存储中的全部任务记录（不删磁盘文件）。
  Future<void> clear() async {
    await _backend.set(_key, '');
  }
}
