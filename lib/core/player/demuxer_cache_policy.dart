/// demuxer 缓存降级策略。
///
/// 计费网络或低内存设备自动收缩 mpv demuxer 缓存，避免后台大量拉流、
/// 低端机缓存挤占前台内存；网络变化时由播放器侧重新 resolve 并应用。
///
/// 数值对齐「同一内核（libmpv）在鸿蒙出货应用」的参考配方（4MiB + 16s +
/// 迟滞 10.7s）：省流档的旧值（2MiB 且无秒数上限）缓冲仅 4–8 秒，带宽
/// 稍有波动就 underrun，表现为肉眼可见的轻微卡顿。
library;

import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../platform/platform_service.dart';

/// demuxer 缓存档位。
enum DemuxerCacheProfile {
  /// 标准档：Wi-Fi / 大内存。32MiB + 预读上限 120s（封顶值不是预分配，
  /// 实际内存随带宽增长到封顶为止），拖动与抗波动余量充足。
  standard(
    maxBytes: 32 * 1024 * 1024,
    maxBackBytes: 32 * 1024 * 1024,
    cacheSecs: 120,
    hysteresisSecs: 80,
  ),

  /// 省流档：计费网络 / 低内存设备。与参考实现一致：4MiB + 16s 迟滞 10.7s，
  /// 足以吸收带宽抖动，又不至于后台偷跑流量。
  low(
    maxBytes: 4 * 1024 * 1024,
    maxBackBytes: 4 * 1024 * 1024,
    cacheSecs: 16,
    hysteresisSecs: 10.7,
  );

  const DemuxerCacheProfile({
    required this.maxBytes,
    required this.maxBackBytes,
    required this.cacheSecs,
    required this.hysteresisSecs,
  });

  /// 前向缓存预算（字节，mpv `demuxer-max-bytes`）。
  final int maxBytes;

  /// 后向缓存预算（字节，mpv `demuxer-max-back-bytes`）。
  final int maxBackBytes;

  /// 预读秒数上限（mpv `cache-secs`；与字节数取先到者）。
  final double cacheSecs;

  /// 缓冲重启迟滞（mpv `demuxer-hysteresis-secs`：低于该秒数才开始
  /// 重新拉流，避免频繁「停一下、缓冲一下」的锯齿行为）。
  final double hysteresisSecs;
}

/// 缓存策略解析器：按网络与设备内存决定档位。
class DemuxerCachePolicyResolver {
  DemuxerCachePolicyResolver({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  bool? _cachedLowMemoryDevice;

  /// 当前网络 / 设备条件下的推荐档位。
  Future<DemuxerCacheProfile> resolve() async {
    final metered = await isMeteredNetwork();
    if (metered) return DemuxerCacheProfile.low;
    if (await isLowMemoryDevice()) return DemuxerCacheProfile.low;
    return DemuxerCacheProfile.standard;
  }

  /// 是否处于计费网络（蜂窝）。
  Future<bool> isMeteredNetwork() async {
    try {
      final results = await _connectivity.checkConnectivity();
      // connectivity_plus 3.x 起蜂窝枚举名为 mobile（cellular 已废弃/移除）。
      return results.contains(ConnectivityResult.mobile);
    } on Object {
      // 平台插件不可用时按非计费处理，保持默认大缓存。
      return false;
    }
  }

  /// 是否为低内存设备（阈值 3GB 物理内存）。
  ///
  /// 移动系平台（Android / 鸿蒙）读 `/proc/meminfo`；其余平台无轻量通道，
  /// 返回 false（桌面端内存普遍充裕，false 正是期望值）。
  Future<bool> isLowMemoryDevice() async {
    final cached = _cachedLowMemoryDevice;
    if (cached != null) return cached;
    var low = false;
    final bool canProbe = !kIsWeb &&
        (PlatformService.instance.isAndroid ||
            PlatformService.instance.isOHOS);
    if (canProbe) {
      try {
        final meminfo = await File('/proc/meminfo').readAsString();
        final match =
            RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(meminfo);
        final totalKb = match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
        low = totalKb > 0 && totalKb < 3 * 1024 * 1024;
      } on Object {
        // 读取失败按常规设备处理。
        low = false;
      }
    }
    _cachedLowMemoryDevice = low;
    return low;
  }

  /// 网络变化流（播放器侧订阅，变化时重新 resolve 并应用档位）。
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _connectivity.onConnectivityChanged;
}
