/// 基于鸿蒙公共下载目录（`Download/<bundleName>`）的下载文件系统实现。
///
/// 背景：鸿蒙手机无法用 dart:io 直接读写公共 Download 目录，目录授权与
/// 读写经应用级原生通道（见 [OhosPublicStorage]）。本类把
/// [DownloadFileSystem] 映射到该通道，路径以 `ohosdoc://<path>␟rel` 编码
/// （与 Android SAF 的编码同构），读取入口由 `resolveSafUri` 等按需落缓存。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;

import '../platform/ohos_public_storage.dart';
import 'download_file_system.dart';

/// 单块写入大小：避免大文件整块过方法通道。
const int _kChunkSize = 1 << 20; // 1 MiB

class OhosDocFileSystem implements DownloadFileSystem {
  OhosDocFileSystem(String rootPath)
      : _root = rootPath.startsWith(kOhosDocScheme)
            ? rootPath
            : encodeOhosDocRoot(rootPath);

  final String _root;

  String _plain(String path) => ohosDocToPlainPath(path);

  @override
  String get basePath => _root;

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    await writeStream(path, _chunked(bytes));
  }

  @override
  Future<void> writeStream(String path, Stream<List<int>> chunks) async {
    final String id = await OhosPublicStorage.openWrite(_plain(path));
    try {
      await for (final List<int> chunk in chunks) {
        if (chunk.isEmpty) continue;
        await OhosPublicStorage.writeChunk(
          id,
          chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
        );
      }
    } finally {
      await OhosPublicStorage.closeWrite(id);
    }
  }

  /// 把 [bytes] 切成不超过 1 MiB 的分块流。
  Stream<List<int>> _chunked(Uint8List bytes) async* {
    for (int i = 0; i < bytes.length; i += _kChunkSize) {
      final int end =
          i + _kChunkSize < bytes.length ? i + _kChunkSize : bytes.length;
      yield Uint8List.sublistView(bytes, i, end);
    }
  }

  @override
  Future<void> writeString(String path, String content) async {
    await writeBytes(path, Uint8List.fromList(utf8.encode(content)));
  }

  @override
  Future<Uint8List> readBytes(String path) async =>
      OhosPublicStorage.readBytes(_plain(path));

  @override
  Future<String> readString(String path) async {
    final Uint8List bytes = await readBytes(path);
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return String.fromCharCodes(bytes);
    }
  }

  @override
  Future<bool> exists(String path) async =>
      OhosPublicStorage.exists(_plain(path));

  @override
  Future<void> delete(String path) async {
    // 不删除授权根目录本身（与 SafFileSystem 的根守卫一致）。
    if (path == _root || !path.contains(kOhosDocSep)) return;
    await OhosPublicStorage.delete(_plain(path));
  }

  @override
  Future<List<String>> listFiles(String dirPath) async {
    try {
      final List<OhosStorageEntry> entries =
          await OhosPublicStorage.list(_plain(dirPath));
      return entries.map((OhosStorageEntry e) => e.name).toList();
    } on PlatformException {
      // 与 PathProviderFileSystem 对齐：路径不是目录（根目录下可能直接有
      // 封面等文件）或不可读时返回空列表，不中断启动扫描。
      return const <String>[];
    }
  }

  @override
  Future<void> createDir(String path) async {
    await OhosPublicStorage.mkdir(_plain(path));
  }

  @override
  String join(String a, String b) => ohosDocJoin(a, b);
}
