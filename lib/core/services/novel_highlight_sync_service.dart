/// 小说划线 / 笔记 WebDAV 细粒度同步服务。
///
/// 远端存储：`nexhub/highlights/<编码后 novelId>.json`（一本书一个文件，
/// 内容 `{novelId, highlights: [...]}`）。与进度同步
/// （`novel_progress_sync_service.dart`）共享 WebDAV 配置 / 密码通道
/// （[CloudSyncConfigStore]），但独立成文件、互不干扰。
///
/// 合并语义（集合并集，无版本向量）：
/// - 同 key（`novelId::chapterIndex::createdAt`）两端都有：以本地为准
///   （本地刚完成的编辑不被云端覆盖）；同 key 内容不同时后上传者胜。
/// - 只在一端存在的 key 直接并入结果集（多端新增互不丢失）。
/// - **删除不跨端传播**：本机删除的划线若已同步过，其他端仍保留
///   （避免墓碑机制的复杂度；需要彻底清理时删除远端文件或用整包恢复）。
///
/// 触发点：阅读器启动静默 [syncOne]（拉取合并 + 上传全集，远端新划线
/// 并入后刷新本章渲染）、退后台 / 退出 [syncOne]（与进度同步同点位，
/// 语义一致故复用同一方法）。任何失败静默返回，不阻塞阅读器。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../novel/novel_highlight_manager.dart';
import 'cloud_sync_service.dart';

/// 一次单书同步的结果。
class NovelHighlightSyncResult {
  /// 从云端并入本地的划线条数。
  final int appliedFromRemote;

  /// 是否成功上传了合并后的全集。
  final bool uploaded;

  const NovelHighlightSyncResult({
    required this.appliedFromRemote,
    required this.uploaded,
  });
}

/// 划线 / 笔记 WebDAV 同步服务。
class NovelHighlightSyncService {
  NovelHighlightSyncService({CloudSyncConfigStore? store})
      : _store = store ?? CloudSyncConfigStore();

  final CloudSyncConfigStore _store;

  /// 细粒度远端目录（相对 WebDAV 根，每本书一个文件）。
  static const String remoteHighlightsDir = 'nexhub/highlights';

  String? _password;

  Future<({String url, String username, String? password})?>
      _loadConfig() async {
    final config = await _store.load();
    if (config.url.isEmpty) return null;
    final pw = _password ??= await _store.loadPassword();
    return (url: config.url, username: config.username, password: pw);
  }

  String _buildUrl(String base, String path) {
    var b = base;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return '$b/$path';
  }

  /// novelId → 远端文件名（与进度同步同一套清洗规则：白名单字符外
  /// 替换为 `_` 并追加 hash 后缀防碰撞）。
  static String remoteBookFileName(String novelId) {
    final safe = novelId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '${safe}_${novelId.hashCode.abs()}.json';
  }

  Dio _dio(String username, String password) {
    final creds = base64Encode(utf8.encode('$username:$password'));
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
      headers: <String, String>{'Authorization': 'Basic $creds'},
    ));
  }

  /// 拉取远端单书快照；无文件 / 失败返回 null。
  Future<List<NovelHighlight>?> _fetchBook(
      Dio dio, String url, String novelId) async {
    try {
      final resp = await dio.get<String>(
        _buildUrl(
            url, '$remoteHighlightsDir/${remoteBookFileName(novelId)}'),
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && (s == 200 || s == 404),
        ),
      );
      if (resp.statusCode != 200 || resp.data == null) return null;
      final decoded =
          jsonDecode(resp.data!) as Map<String, dynamic>;
      final list = decoded['highlights'] as List?;
      if (list == null) return null;
      return <NovelHighlight>[
        for (final item in list)
          if (item is Map<String, dynamic>)
            NovelHighlight.fromJson(item),
      ];
    } on Object {
      return null;
    }
  }

  /// 上传单书全集（先 MKCOL 建目录再 PUT）。失败返回 false。
  Future<bool> _putBook(
      Dio dio, String url, List<NovelHighlight> highlights) async {
    if (highlights.isEmpty) return false;
    final novelId = highlights.first.novelId;
    try {
      for (final dir in const <String>['nexhub', remoteHighlightsDir]) {
        try {
          await dio.request<void>(
            '${_buildUrl(url, dir)}/',
            data: '',
            options: Options(method: 'MKCOL', validateStatus: (s) => s! < 500),
          );
        } on Object {
          // MKCOL 失败不阻断：部分服务器自动创建父目录。
        }
      }
      final body = jsonEncode(<String, dynamic>{
        'novelId': novelId,
        'highlights': <Map<String, dynamic>>[
          for (final h in highlights) h.toJson(),
        ],
      });
      final resp = await dio.put<String>(
        _buildUrl(url, '$remoteHighlightsDir/${remoteBookFileName(novelId)}'),
        data: body,
        options: Options(
          headers: <String, String>{'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
      );
      return resp.statusCode != null && resp.statusCode! >= 200;
    } on Object {
      return false;
    }
  }

  /// 单书同步：拉取远端 → 云端新增项并入本地 → 上传合并全集。
  ///
  /// 返回 (并入条数, 是否上传成功)；未配置云同步时两者为零/false。
  /// 本地与远端内容一致时跳过上传（省流量）。
  Future<NovelHighlightSyncResult> syncOne(String novelId) async {
    final cfg = await _loadConfig();
    if (cfg == null || cfg.password == null || cfg.password!.isEmpty) {
      return const NovelHighlightSyncResult(
          appliedFromRemote: 0, uploaded: false);
    }
    final dio = _dio(cfg.username, cfg.password!);
    try {
      final manager = NovelHighlightManager();
      final local = await manager.listFor(novelId);
      final remote = await _fetchBook(dio, cfg.url, novelId);

      // 云端新增项（本地无此 key）并入本地。
      final localKeys = local.map((h) => h.key).toSet();
      final incoming = <NovelHighlight>[
        if (remote != null)
          for (final r in remote)
            if (!localKeys.contains(r.key)) r,
      ];
      for (final h in incoming) {
        await manager.add(h);
      }
      final merged = <NovelHighlight>[...local, ...incoming];

      // 无远端且本地为空：无需上传（也避免为空书建远端文件）。
      if (merged.isEmpty) {
        return const NovelHighlightSyncResult(
            appliedFromRemote: 0, uploaded: false);
      }

      // 内容与远端一致时跳过上传（比较 key+内容指纹：笔记/颜色编辑
      // 不会被 key 集合相等误判为无变化）。
      if (remote != null && _fingerprint(remote) == _fingerprint(merged)) {
        return NovelHighlightSyncResult(
            appliedFromRemote: incoming.length, uploaded: false);
      }

      final ok = await _putBook(dio, cfg.url, merged);
      return NovelHighlightSyncResult(
          appliedFromRemote: incoming.length, uploaded: ok);
    } finally {
      dio.close(force: true);
    }
  }

  /// 集合内容指纹：`key=note|color|effect`，按 key 排序后拼接。
  /// 用于判断本地与远端是否真无差异（与存储顺序无关）。
  static String _fingerprint(Iterable<NovelHighlight> highlights) {
    final m = <String, String>{
      for (final h in highlights)
        h.key: '${h.note ?? ''}|${h.color}|${h.effect}',
    };
    final keys = m.keys.toList()..sort();
    return <String>[for (final k in keys) '$k=${m[k]}'].join(';');
  }
}
