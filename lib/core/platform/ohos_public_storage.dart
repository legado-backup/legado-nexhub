/// 鸿蒙公共下载目录（`Download/<bundleName>`）桥接。
///
/// 背景：鸿蒙手机不支持文件夹选择（FolderSelection 仅 2in1），且公共
/// Download 目录无法用 dart:io 直接读写。`DocumentViewPicker` 的 DOWNLOAD
/// 模式由系统创建并**持久授权** `Download/<bundleName>`，是手机上空唯一
/// 可写的用户可见位置（系统「文件」可见，免额外权限）。
///
/// 目录读写经应用级原生通道 `nexhub/ohos_storage`（见 OhosStoragePlugin）：
/// - 原生侧只接受**真实路径**（`fileUri.FileUri(uri).path`），避免 Dart
///   解析文档 URI；
/// - 跨模块流转的路径用 [encodeOhosDocRoot] 编码为 `ohosdoc://<path>` 并
///   以 `␟` 分隔相对段（与 Android SAF 的 `<treeUri>␟rel` 同构），
///   供 [resolveSafUri] 等读取入口识别与按需落缓存；
/// - 大文件写入走 openWrite/writeChunk/closeWrite 会话，拷贝走
///   [copyToCache]（原生分块），不整块过方法通道。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_log.dart';

/// 鸿蒙公共目录路径的 scheme 前缀。
const String kOhosDocScheme = 'ohosdoc://';

/// 编码路径中根路径与相对段的分隔符（与 Android SAF 编码保持一致）。
const String kOhosDocSep = '␟';

/// 是否为鸿蒙公共目录编码路径。
bool isOhosDocPath(String path) => path.startsWith(kOhosDocScheme);

/// 真实路径 → 编码根路径。
String encodeOhosDocRoot(String plainPath) =>
    '$kOhosDocScheme$plainPath';

/// 编码路径 → 原生可读的真实路径。
String ohosDocToPlainPath(String encoded) => encoded
    .substring(kOhosDocScheme.length)
    .replaceAll(kOhosDocSep, '/');

/// 编码路径拼接子项（与 Android SAF 的 join 语义一致）。
///
/// 首次拼接插入 `␟` 区分授权根与相对段；后续用 `/` 续接相对段。
String ohosDocJoin(String base, String child) {
  if (!base.contains(kOhosDocSep)) return '$base$kOhosDocSep$child';
  return base.endsWith('/') ? '$base$child' : '$base/$child';
}

/// 原生目录项。
class OhosStorageEntry {
  const OhosStorageEntry({
    required this.name,
    required this.isDir,
    required this.size,
  });

  final String name;
  final bool isDir;
  final int size;
}

/// 公共下载目录授权与文件读写。
class OhosPublicStorage {
  OhosPublicStorage._();

  static const MethodChannel _channel =
      MethodChannel('nexhub/ohos_storage');

  /// 已授权的系统目录根（编码路径）在 SharedPreferences 中的键。
  static const String _kRootPrefsKey = 'ohos_public_storage_root';

  /// 主动拉起系统授权（DOWNLOAD 模式，无需选择文件）。
  static Future<String?> requestRoot() async {
    final String? stored = await _readStoredRoot();
    if (stored != null && await checkPath(ohosDocToPlainPath(stored))) {
      return stored;
    }
    return _requestRoot();
  }

  static Future<String?> _requestRoot() async {
    try {
      final Map<String, dynamic>? result =
          await _channel.invokeMapMethod<String, dynamic>('requestDownloadDir');
      final String? plain = result?['path'] as String?;
      if (plain == null || plain.isEmpty) return null;
      final String encoded = encodeOhosDocRoot(plain);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kRootPrefsKey, encoded);
      AppLog.instance.i('[鸿蒙公共目录] 已授权: $plain');
      return encoded;
    } on PlatformException catch (e) {
      AppLog.instance.w('[鸿蒙公共目录] 授权失败: ${e.code} ${e.message}');
      rethrow;
    }
  }

  static Future<String?> _readStoredRoot() async {
    final prefs = await SharedPreferences.getInstance();
    final String? stored = prefs.getString(_kRootPrefsKey);
    if (stored == null || stored.isEmpty) return null;
    return stored;
  }

  static Future<bool> checkPath(String plainPath) async {
    try {
      final bool? ok = await _channel.invokeMethod<bool>(
        'checkPath',
        <String, dynamic>{'path': plainPath},
      );
      return ok ?? false;
    } on PlatformException catch (e) {
      AppLog.instance.w('[鸿蒙公共目录] 检查路径失败: ${e.code} ${e.message}');
      return false;
    }
  }

  static Future<void> mkdir(String plainPath) async {
    await _channel.invokeMethod<void>(
      'mkdir',
      <String, dynamic>{'path': plainPath},
    );
  }

  static Future<bool> exists(String plainPath) async {
    final bool? ok = await _channel.invokeMethod<bool>(
      'exists',
      <String, dynamic>{'path': plainPath},
    );
    return ok ?? false;
  }

  static Future<void> delete(String plainPath) async {
    await _channel.invokeMethod<void>(
      'delete',
      <String, dynamic>{'path': plainPath},
    );
  }

  static Future<List<OhosStorageEntry>> list(String plainPath) async {
    final List<dynamic>? raw = await _channel.invokeListMethod<dynamic>(
      'list',
      <String, dynamic>{'path': plainPath},
    );
    if (raw == null) return const <OhosStorageEntry>[];
    final result = <OhosStorageEntry>[];
    for (final dynamic item in raw) {
      if (item is! Map) continue;
      final String name = '${item['name'] ?? ''}';
      if (name.isEmpty) continue;
      result.add(OhosStorageEntry(
        name: name,
        isDir: item['isDir'] == true,
        size: (item['size'] as num?)?.toInt() ?? 0,
      ));
    }
    return result;
  }

  static Future<Uint8List> readBytes(String plainPath) async {
    final Uint8List? bytes = await _channel.invokeMethod<Uint8List>(
      'readBytes',
      <String, dynamic>{'path': plainPath},
    );
    return bytes ?? Uint8List(0);
  }

  static Future<void> writeBytes(String plainPath, Uint8List bytes) async {
    await _channel.invokeMethod<void>(
      'writeBytes',
      <String, dynamic>{'path': plainPath, 'bytes': bytes},
    );
  }

  /// 打开写会话，返回会话 id（用于分块写入大文件）。
  static Future<String> openWrite(String plainPath) async {
    final String? id = await _channel.invokeMethod<String>(
      'openWrite',
      <String, dynamic>{'path': plainPath},
    );
    if (id == null || id.isEmpty) {
      throw FileSystemException('无法打开写入会话', plainPath);
    }
    return id;
  }

  static Future<void> writeChunk(String id, Uint8List bytes) async {
    await _channel.invokeMethod<void>(
      'writeChunk',
      <String, dynamic>{'id': id, 'bytes': bytes},
    );
  }

  static Future<void> closeWrite(String id) async {
    await _channel.invokeMethod<void>(
      'closeWrite',
      <String, dynamic>{'id': id},
    );
  }

  /// 原生分块拷贝到应用缓存路径，返回写入字节数。
  static Future<int> copyToCache(String srcPlain, String dstPlain) async {
    final int? size = await _channel.invokeMethod<int>(
      'copyToCache',
      <String, dynamic>{'src': srcPlain, 'dst': dstPlain},
    );
    return size ?? 0;
  }

  // ─────────────── 文档路径 → 应用缓存 ───────────────

  static final Map<String, String> _resolved = <String, String>{};
  static final Map<String, Future<String>> _inflight =
      <String, Future<String>>{};

  /// 把 `ohosdoc://` 编码路径落为应用缓存里的真实文件，供 dart:io /
  /// media_kit / 阅读器使用（按编码路径记忆化）。
  static Future<String> materialize(String encoded) async {
    final String? cached = _resolved[encoded];
    if (cached != null &&
        File(cached).existsSync() &&
        File(cached).lengthSync() > 0) {
      return cached;
    }
    final Future<String>? running = _inflight[encoded];
    if (running != null) return running;
    final Future<String> future = _materialize(encoded);
    _inflight[encoded] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(encoded);
    }
  }

  static Future<String> _materialize(String encoded) async {
    final String src = ohosDocToPlainPath(encoded);
    if (!await exists(src)) {
      throw FileSystemException('文件不存在（可能被移动或删除）', encoded);
    }
    final Directory temp = await getTemporaryDirectory();
    final Directory cacheDir =
        Directory(p.join(temp.path, 'ohos_doc_cache'));
    if (!cacheDir.existsSync()) {
      await cacheDir.create(recursive: true);
    }
    final String target =
        p.join(cacheDir.path, 'ohos_${encoded.hashCode}${_ext(encoded)}');
    final int size = await copyToCache(src, target);
    final File targetFile = File(target);
    if (size <= 0 || !targetFile.existsSync() || targetFile.lengthSync() == 0) {
      throw FileSystemException('源文件为空或不可读', encoded);
    }
    _resolved[encoded] = target;
    AppLog.instance.d('[鸿蒙公共目录] 落缓存: $encoded -> $target ($size B)');
    return target;
  }

  static String _ext(String encoded) {
    final String last = encoded.split('/').last;
    final int dot = last.lastIndexOf('.');
    if (dot <= 0 || dot >= last.length - 1) return '';
    final String ext = last.substring(dot).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(ext) ? ext : '';
  }
}
