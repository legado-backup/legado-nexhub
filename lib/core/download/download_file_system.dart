/// 下载文件系统抽象（文档 /）。
///
/// 将平台文件操作抽象为接口，便于测试注入内存实现。
/// 生产环境使用 [PathProviderFileSystem]；测试使用 [InMemoryFileSystem]。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../platform/platform_service.dart';

/// 旧版本硬编码的桌面默认路径。
///
/// 历史配置可能仍保存该值；现在它只用于识别「未设置」，新代码不再写入。
const String kLegacyDefaultDownloadPath = 'D:/Downloads';

/// 配置值是否等价于「未设置下载路径」（空串或旧版硬编码默认值）。
bool isUnsetDownloadPath(String path) =>
    path.isEmpty || path == kLegacyDefaultDownloadPath;

/// 平台相关的默认下载基路径。
///
/// - Android：优先应用私有外部存储 `<pkg>/files/Download`（可被 dart:io 直接
/// 写入，修复 108：旧默认 `D:/Downloads` 在 Android 上不存在，导致下载无法
/// 进行）。部分设备 / 副用户 / 工作资料下 `getExternalStorageDirectory()`
/// 返回 null，此时回落应用文档目录（内部存储，始终可写），**绝不**回落到
/// Windows 专属的 `D:/Downloads`——那在 Android 上是相对路径，写入必然失败
/// （Android 高版本「所有下载都失败」的根因之一）。
/// - 鸿蒙：应用文档目录（沙箱内唯一稳定可写路径；系统公共目录需原生文件
///   授权，见 `ohos_public_storage.dart`），同样不使用 `D:/Downloads`。
/// - 桌面：系统「下载」目录（Windows 为 `%USERPROFILE%\Downloads`）；取不到
///   时回落应用文档目录下的 Download，不再假设存在 D 盘。
Future<String> defaultDownloadPath() async {
  if (PlatformService.instance.isOHOS) {
    final Directory docs = await getApplicationDocumentsDirectory();
    return '${docs.path}${docs.path.endsWith('/') ? '' : '/'}Download';
  }
  if (PlatformService.instance.isAndroid) {
    final Directory? dir = await getExternalStorageDirectory();
    if (dir != null) {
      return '${dir.path}${dir.path.endsWith('/') ? '' : '/'}Download';
    }
    final Directory docs = await getApplicationDocumentsDirectory();
    return '${docs.path}${docs.path.endsWith('/') ? '' : '/'}Download';
  }
  try {
    final Directory? downloads = await getDownloadsDirectory();
    if (downloads != null && downloads.path.isNotEmpty) {
      return downloads.path;
    }
  } on Object {
    // 平台不支持系统下载目录（如 iOS）时继续回落应用文档目录。
  }
  final Directory docs = await getApplicationDocumentsDirectory();
  final String sep = Platform.pathSeparator;
  return '${docs.path}${docs.path.endsWith(sep) ? '' : sep}Download';
}

/// 生效的下载路径：已设置则原样返回，未设置时解析平台默认目录。
Future<String> resolveDownloadPath(String configured) async =>
    isUnsetDownloadPath(configured)
        ? defaultDownloadPath()
        : configured;

/// 文件系统后端接口。
abstract class DownloadFileSystem {
  /// 获取下载基路径。
  String get basePath;

  /// 写入文件（字节），自动创建父目录。
  Future<void> writeBytes(String path, Uint8List bytes);

  /// 流式写入文件（分块），自动创建父目录。
  ///
  /// 用于大文件（视频/长音频）：避免整块读入内存导致 OOM 卡退。各实现保证
  /// 逐块落盘，内存占用恒定（SAF 走 writeFileStream 分块通道，与写 cbz 一致）。
  Future<void> writeStream(String path, Stream<List<int>> chunks);

  /// 写入文件（文本），自动创建父目录。
  Future<void> writeString(String path, String content);

  /// 读取文件字节。
  Future<Uint8List> readBytes(String path);

  /// 读取文件文本。
  Future<String> readString(String path);

  /// 文件是否存在。
  Future<bool> exists(String path);

  /// 删除文件或目录（递归）。
  Future<void> delete(String path);

  /// 列出目录下的文件名（不含路径前缀）。
  Future<List<String>> listFiles(String dirPath);

  /// 创建目录（递归）。
  Future<void> createDir(String path);

  /// 拼接路径。
  String join(String a, String b);
}

/// 基于 path_provider + dart:io 的生产实现。
class PathProviderFileSystem implements DownloadFileSystem {
  PathProviderFileSystem(this._basePath);

  final String _basePath;

  @override
  String get basePath => _basePath;

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  @override
  Future<void> writeStream(String path, Stream<List<int>> chunks) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final IOSink sink = file.openWrite();
    try {
      await for (final chunk in chunks) {
        sink.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  @override
  Future<void> writeString(String path, String content) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  @override
  Future<Uint8List> readBytes(String path) async =>
      await File(path).readAsBytes();

  @override
  Future<String> readString(String path) async =>
      await File(path).readAsString();

  @override
  Future<bool> exists(String path) async => File(path).existsSync();

  @override
  Future<void> delete(String path) async {
    final f = File(path);
    if (await f.exists()) {
      await f.delete();
      return;
    }
    final d = Directory(path);
    if (d.existsSync()) {
      await d.delete(recursive: true);
    }
  }

  @override
  Future<List<String>> listFiles(String dirPath) async {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return <String>[];
    final entries = <String>[];
    await for (final e in dir.list()) {
      entries.add(e.uri.pathSegments.last);
    }
    return entries;
  }

  @override
  Future<void> createDir(String path) async {
    await Directory(path).create(recursive: true);
  }

  @override
  String join(String a, String b) => '$a${Platform.pathSeparator}$b';
}

/// 内存文件系统（测试用）。
class InMemoryFileSystem implements DownloadFileSystem {
  InMemoryFileSystem({this.basePath = '/tmp/downloads'});

  @override
  final String basePath;

  final Map<String, Uint8List> _files = {};

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    _files[path] = bytes;
  }

  @override
  Future<void> writeStream(String path, Stream<List<int>> chunks) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final chunk in chunks) {
      builder.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    }
    _files[path] = builder.takeBytes();
  }

  @override
  Future<void> writeString(String path, String content) async {
    _files[path] = Uint8List.fromList(content.codeUnits);
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final f = _files[path];
    if (f == null) throw FileSystemException('Not found', path);
    return f;
  }

  @override
  Future<String> readString(String path) async {
    final f = _files[path];
    if (f == null) throw FileSystemException('Not found', path);
    return String.fromCharCodes(f);
  }

  @override
  Future<bool> exists(String path) async {
    if (_files.containsKey(path)) return true;
    // 目录模拟：某路径下若存在子文件（前缀 `$path/`），视为该目录存在。
    // 真实文件系统（PathProviderFileSystem）对目录的 exists 同理返回 true。
    final prefix = '$path/';
    return _files.keys.any((k) => k.startsWith(prefix));
  }

  @override
  Future<void> delete(String path) async {
    _files.remove(path);
    // Also remove any files under this path prefix (directory simulation)
    final prefix = '$path/';
    _files.removeWhere((key, _) => key.startsWith(prefix));
  }

  @override
  Future<List<String>> listFiles(String dirPath) async {
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    final result = <String>[];
    for (final key in _files.keys) {
      if (key.startsWith(prefix)) {
        final rel = key.substring(prefix.length);
        // Only direct children (no further separators)
        if (!rel.contains('/')) {
          result.add(rel);
        }
      }
    }
    return result;
  }

  @override
  Future<void> createDir(String path) async {
    // No-op for in-memory
  }

  @override
  String join(String a, String b) => '$a/$b';

  /// 直接检查文件是否存在（同步，测试辅助）。
  bool hasFile(String path) => _files.containsKey(path);

  /// 获取文件内容（同步，测试辅助）。
  Uint8List? getFile(String path) => _files[path];
}
