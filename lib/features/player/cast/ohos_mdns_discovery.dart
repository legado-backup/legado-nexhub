import 'package:cast/cast.dart';
import 'package:flutter/services.dart';

/// 鸿蒙投屏设备发现桥（`nexhub/mdns`）。
///
/// cast 包的设备发现依赖 bonsoir，后者没有鸿蒙平台实现。鸿蒙改走 ArkTS
/// `@ohos.net.mdns`（见 ohos/entry/src/main/ets/plugins/MdnsDiscoveryPlugin.ets），
/// 回传结构与 bonsoir 解析结果对齐，会话与媒体控制仍复用 cast 包的纯 Dart 实现。
class OhosMdnsDiscovery {
  OhosMdnsDiscovery._();

  static const MethodChannel _channel = MethodChannel('nexhub/mdns');

  /// Chromecast 的 mDNS 服务类型。
  static const String _serviceType = '_googlecast._tcp';

  /// 搜索局域网内的 Chromecast 设备，[timeout] 后返回已发现的设备。
  ///
  /// 原生通道失败时抛 [PlatformException]，由调用方回滚并提示。
  static Future<List<CastDevice>> search({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final List<Object?>? raw = await _channel.invokeListMethod<Object?>(
      'discover',
      <String, Object?>{
        'serviceType': _serviceType,
        'timeoutMs': timeout.inMilliseconds,
      },
    );
    final List<CastDevice> devices = <CastDevice>[];
    for (final Object? item in raw ?? const <Object?>[]) {
      if (item is! Map) continue;
      final Object? serviceName = item['serviceName'];
      final Object? host = item['host'];
      final Object? port = item['port'];
      if (serviceName is! String ||
          serviceName.isEmpty ||
          host is! String ||
          host.isEmpty ||
          port is! int ||
          port <= 0) {
        continue;
      }
      final Object? name = item['name'];
      final Map<String, String> extras = <String, String>{};
      final Object? attributes = item['attributes'];
      if (attributes is Map) {
        attributes.forEach((Object? key, Object? value) {
          if (key is String && value is String) extras[key] = value;
        });
      }
      devices.add(
        CastDevice(
          serviceName: serviceName,
          name: name is String && name.isNotEmpty ? name : serviceName,
          host: host,
          port: port,
          extras: extras,
        ),
      );
    }
    return devices;
  }
}
