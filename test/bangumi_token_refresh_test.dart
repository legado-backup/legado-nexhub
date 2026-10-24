/// Bangumi token 自动续期回归测试。
///
/// 覆盖：
/// - [BangumiClient] 带 token 的请求收到 401 时触发续期回调，成功后用新
///   token 立即重试一次；
/// - 续期失败 / 匿名请求不重试，401 原样抛出；
/// - [BangumiAuth] 收到 401 后用 refresh_token 换取新 access_token 并落盘，
///   无 refresh_token（个人 token 登录）时不访问 token 端点。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/services/bangumi/bangumi_auth.dart';
import 'package:nexhub/core/services/bangumi/bangumi_client.dart';

/// 可编程 Dio 适配器：按 [handler] 返回响应，并记录每个请求。
class _RouteAdapter implements HttpClientAdapter {
  _RouteAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int statusCode, Map<String, dynamic> body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    statusCode,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    },
  );
}

String _pathOf(RequestOptions options) =>
    Uri.tryParse(options.path)?.path ?? options.path;

/// 与生产 [BangumiClient._buildDio] 一致：非 2xx 也返回响应而不抛异常。
Dio _dioWith(_RouteAdapter adapter) => Dio(
      BaseOptions(validateStatus: (_) => true),
    )..httpClientAdapter = adapter;

/// 内存版安全存储：不触碰平台通道。
class _MemoryStorage extends FlutterSecureStorage {
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    data.remove(key);
  }
}

void main() {
  group('BangumiClient 401 续期重试', () {
    test('续期成功后用新 token 立即重试一次', () async {
      var calls = 0;
      final adapter = _RouteAdapter((options) {
        calls++;
        if (calls == 1) {
          return _json(401, <String, dynamic>{
            'description': "access token has been expired or doesn't exist",
          });
        }
        return _json(200, <String, dynamic>{
          'id': 1,
          'username': 'tester',
          'nickname': 'Tester',
        });
      });
      final client = BangumiClient(dio: _dioWith(adapter))
        ..token = 'stale-token';
      var refreshCalls = 0;
      client.onUnauthorized = () async {
        refreshCalls++;
        client.token = 'fresh-token';
        return true;
      };

      final me = await client.fetchMe();

      expect(me.username, 'tester');
      expect(refreshCalls, 1);
      expect(adapter.requests, hasLength(2));
      expect(
        adapter.requests.first.headers['Authorization'],
        'Bearer stale-token',
      );
      expect(
        adapter.requests.last.headers['Authorization'],
        'Bearer fresh-token',
      );
    });

    test('续期失败时不再重试，401 原样抛出', () async {
      final adapter = _RouteAdapter(
        (_) => _json(401, <String, dynamic>{
          'description': "access token has been expired or doesn't exist",
        }),
      );
      final client = BangumiClient(dio: _dioWith(adapter))
        ..token = 'stale-token';
      var refreshCalls = 0;
      client.onUnauthorized = () async {
        refreshCalls++;
        return false;
      };

      await expectLater(
        client.fetchMe(),
        throwsA(
          isA<BangumiApiException>()
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
      expect(refreshCalls, 1);
      expect(adapter.requests, hasLength(1));
    });

    test('匿名请求的 401 不触发续期', () async {
      final adapter = _RouteAdapter(
        (_) => _json(401, <String, dynamic>{'description': 'unauthorized'}),
      );
      final client = BangumiClient(dio: _dioWith(adapter));
      var refreshCalls = 0;
      client.onUnauthorized = () async {
        refreshCalls++;
        return true;
      };

      await expectLater(
        client.fetchMe(),
        throwsA(
          isA<BangumiApiException>()
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
      expect(refreshCalls, 0);
      expect(adapter.requests, hasLength(1));
    });
  });

  group('BangumiAuth 401 自动续期', () {
    test('用 refresh_token 换新 access_token 并重试原请求', () async {
      var meCalls = 0;
      RequestOptions? tokenRequest;
      final adapter = _RouteAdapter((options) {
        final path = _pathOf(options);
        if (path == '/oauth/access_token') {
          tokenRequest = options;
          return _json(200, <String, dynamic>{
            'access_token': 'fresh-token',
            'refresh_token': 'refresh-new',
            'expires_in': 604800,
          });
        }
        if (path == '/v0/me') {
          meCalls++;
          if (meCalls == 1) {
            return _json(401, <String, dynamic>{
              'description': "access token has been expired or doesn't exist",
            });
          }
          return _json(200, <String, dynamic>{
            'id': 1,
            'username': 'tester',
            'nickname': 'Tester',
          });
        }
        return _json(404, <String, dynamic>{});
      });
      final storage = _MemoryStorage()
        ..data['bangumi_access_token'] = 'stale-token'
        ..data['bangumi_username'] = 'tester'
        ..data['bangumi_refresh_token'] = 'refresh-old'
        ..data['bangumi_expires_at'] = '1';
      final client = BangumiClient(dio: _dioWith(adapter));
      final auth = BangumiAuth(client: client, storage: storage);
      await auth.init();
      expect(auth.isLoggedIn, isTrue);

      await auth.refreshProfile();

      expect(meCalls, 2);
      expect(client.token, 'fresh-token');
      expect(storage.data['bangumi_access_token'], 'fresh-token');
      expect(storage.data['bangumi_refresh_token'], 'refresh-new');
      expect(
        adapter.requests.map(_pathOf),
        <String>['/v0/me', '/oauth/access_token', '/v0/me'],
      );
      final form = tokenRequest!.data as Map<String, String>;
      expect(form['grant_type'], 'refresh_token');
      expect(form['refresh_token'], 'refresh-old');
    });

    test('无 refresh_token 时不访问 token 端点，401 原样抛出', () async {
      final adapter = _RouteAdapter(
        (_) => _json(401, <String, dynamic>{
          'description': "access token has been expired or doesn't exist",
        }),
      );
      final storage = _MemoryStorage()
        ..data['bangumi_access_token'] = 'personal-token'
        ..data['bangumi_username'] = 'tester';
      final client = BangumiClient(dio: _dioWith(adapter));
      final auth = BangumiAuth(client: client, storage: storage);
      await auth.init();

      await expectLater(
        auth.refreshProfile(),
        throwsA(
          isA<BangumiApiException>()
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
      expect(adapter.requests.map(_pathOf), <String>['/v0/me']);
    });
  });
}
