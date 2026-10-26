/// 互动阅读分格清单（`comic_panels` JSON）的解析与校验。
///
/// 清单只描述「哪一块是分格、如何聚焦、用哪个素材」，不携带像素。
/// 素材由宿主加载后通过 `panelClips` 传入渲染层；清单本身是可缓存的
/// 运行时 sidecar，不属于引擎 `configHash`。
library;

import 'dart:convert' as convert;
import 'dart:typed_data';
import 'dart:ui' show Rect;

/// 分格揭示方式。
enum PanelReveal {
  /// 斜锯齿撕开（默认）。
  tear,

  /// 淡入。
  fade,

  /// 直接显示。
  none,
}

/// 分格可选独立素材引用（T2）。
class PanelClipRef {
  const PanelClipRef({required this.asset, this.loop = true});

  /// 素材标识，由宿主的 `loadClip` 解析（磁盘相对路径 / 资产键 / URL 均可）。
  final String asset;

  /// 是否循环播放；false 时停在末帧。
  final bool loop;
}

/// 单个分格定义。矩形使用源图归一化坐标（左上原点，[0,1]）。
class PanelSpec {
  const PanelSpec({
    required this.id,
    required this.rect,
    this.reveal = PanelReveal.tear,
    this.dim = 0.42,
    this.glow = 0.22,
    this.scale = 1.012,
    this.clip,
  });

  final String id;
  final Rect rect;
  final PanelReveal reveal;

  /// 非焦点区域压暗强度，0 = 不压暗。
  final double dim;

  /// 聚焦格辉光强度，0 = 不发光。
  final double glow;

  /// 聚焦时的轻微放大比例，1 = 不放大。
  final double scale;

  /// 可选格级素材；为 null 时复用整页 GIF 并裁剪到本格。
  final PanelClipRef? clip;
}

/// 一份 `comic_panels` 清单。
class PanelManifest {
  const PanelManifest({
    required this.version,
    required this.panels,
  });

  static const String kind = 'comic_panels';
  static const int currentVersion = 1;

  final int version;
  final List<PanelSpec> panels;

  /// 从 UTF-8 JSON 字节解析；格式错误抛 [ArgumentError]。
  factory PanelManifest.fromBytes(Uint8List bytes) {
    final Object? raw;
    try {
      raw = convert.jsonDecode(convert.utf8.decode(bytes));
    } on FormatException catch (e) {
      throw ArgumentError('comic_panels: JSON 解析失败 ($e)');
    }
    return PanelManifest.fromJson(raw);
  }

  factory PanelManifest.fromJson(Object? raw) {
    if (raw is! Map) {
      throw ArgumentError('comic_panels: 根节点必须是 JSON 对象');
    }
    final map = raw.cast<String, dynamic>();
    if (map['kind'] != kind) {
      throw ArgumentError('comic_panels: kind 必须为 $kind，'
          'got ${map['kind']}');
    }
    final version = map['version'];
    if (version is! int || version != currentVersion) {
      throw ArgumentError('comic_panels: 不支持的 version $version'
          '（当前 $currentVersion）');
    }
    final rawPanels = map['panels'];
    if (rawPanels is! List || rawPanels.isEmpty) {
      throw ArgumentError('comic_panels: panels 必须是非空数组');
    }
    final seen = <String>{};
    final panels = <PanelSpec>[];
    for (final entry in rawPanels) {
      if (entry is! Map) {
        throw ArgumentError('comic_panels: 每个 panel 必须是对象');
      }
      final p = entry.cast<String, dynamic>();
      final id = p['id'];
      if (id is! String || id.isEmpty) {
        throw ArgumentError('comic_panels: panel.id 必须是非空字符串');
      }
      if (!seen.add(id)) {
        throw ArgumentError('comic_panels: panel.id 重复: $id');
      }
      final rect = _parseRect(p['rect'], id);
      final reveal = _parseReveal(p['reveal'], id);
      final dim = _parseUnit(p['dim'], 'dim', id, 0.42);
      final glow = _parseUnit(p['glow'], 'glow', id, 0.22);
      final scale = _parseScale(p['scale'], id);
      final clip = _parseClip(p['clip'], id);
      panels.add(PanelSpec(
        id: id,
        rect: rect,
        reveal: reveal,
        dim: dim,
        glow: glow,
        scale: scale,
        clip: clip,
      ));
    }
    return PanelManifest(version: currentVersion, panels: panels);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'version': version,
        'panels': <Map<String, dynamic>>[
          for (final p in panels)
            <String, dynamic>{
              'id': p.id,
              'rect': <double>[p.rect.left, p.rect.top, p.rect.right,
                  p.rect.bottom],
              'reveal': p.reveal.name,
              'dim': p.dim,
              'glow': p.glow,
              'scale': p.scale,
              if (p.clip != null)
                'clip': <String, dynamic>{
                  'asset': p.clip!.asset,
                  'loop': p.clip!.loop,
                },
            },
        ],
      };

  static Rect _parseRect(Object? raw, String id) {
    if (raw is! List || raw.length != 4) {
      throw ArgumentError('comic_panels[$id]: rect 必须是 4 个数字'
          ' [left, top, right, bottom]');
    }
    final values = <double>[];
    for (final v in raw) {
      if (v is! num) {
        throw ArgumentError('comic_panels[$id]: rect 含非数字');
      }
      final d = v.toDouble();
      if (!d.isFinite) {
        throw ArgumentError('comic_panels[$id]: rect 含非有限数');
      }
      values.add(d);
    }
    final Rect rect = Rect.fromLTRB(values[0], values[1], values[2], values[3]);
    if (rect.left < 0 ||
        rect.top < 0 ||
        rect.right > 1 ||
        rect.bottom > 1 ||
        rect.right <= rect.left ||
        rect.bottom <= rect.top) {
      throw ArgumentError('comic_panels[$id]: rect 必须满足 '
          '0 <= l < r <= 1 且 0 <= t < b <= 1，got $raw');
    }
    return rect;
  }

  static PanelReveal _parseReveal(Object? raw, String id) {
    if (raw == null) return PanelReveal.tear;
    if (raw is! String) {
      throw ArgumentError('comic_panels[$id]: reveal 必须是字符串');
    }
    for (final v in PanelReveal.values) {
      if (v.name == raw) return v;
    }
    throw ArgumentError('comic_panels[$id]: 未知 reveal "$raw"');
  }

  static double _parseUnit(Object? raw, String field, String id,
      double fallback) {
    if (raw == null) return fallback;
    if (raw is! num) {
      throw ArgumentError('comic_panels[$id]: $field 必须是数字');
    }
    final d = raw.toDouble();
    if (!d.isFinite || d < 0 || d > 1) {
      throw ArgumentError('comic_panels[$id]: $field 必须在 [0,1]，got $raw');
    }
    return d;
  }

  static double _parseScale(Object? raw, String id) {
    if (raw == null) return 1.012;
    if (raw is! num) {
      throw ArgumentError('comic_panels[$id]: scale 必须是数字');
    }
    final d = raw.toDouble();
    if (!d.isFinite || d < 1 || d > 1.2) {
      throw ArgumentError('comic_panels[$id]: scale 必须在 [1,1.2]，got $raw');
    }
    return d;
  }

  static PanelClipRef? _parseClip(Object? raw, String id) {
    if (raw == null) return null;
    if (raw is! Map) {
      throw ArgumentError('comic_panels[$id]: clip 必须是对象');
    }
    final map = raw.cast<String, dynamic>();
    final asset = map['asset'];
    if (asset is! String || asset.isEmpty) {
      throw ArgumentError('comic_panels[$id]: clip.asset 必须是非空字符串');
    }
    final loop = map['loop'];
    if (loop != null && loop is! bool) {
      throw ArgumentError('comic_panels[$id]: clip.loop 必须是布尔值');
    }
    return PanelClipRef(asset: asset, loop: loop as bool? ?? true);
  }
}

/// 清单与已加载的格级素材。
class LoadedPanelManifest {
  const LoadedPanelManifest({required this.manifest, required this.clips});

  final PanelManifest manifest;

  /// panelId → 素材字节。没有 `clip` 的面板不在表中。
  final Map<String, Uint8List> clips;
}

/// 解析清单并按需加载格级素材。同一 `clip.asset` 只调用一次 [loadClip]。
Future<LoadedPanelManifest> loadPanelManifest(
  Uint8List bytes, {
  Future<Uint8List> Function(String asset)? loadClip,
}) async {
  final manifest = PanelManifest.fromBytes(bytes);
  if (loadClip == null) {
    return LoadedPanelManifest(
        manifest: manifest, clips: const <String, Uint8List>{});
  }
  final byAsset = <String, Uint8List>{};
  final clips = <String, Uint8List>{};
  for (final panel in manifest.panels) {
    final ref = panel.clip;
    if (ref == null) continue;
    final data = byAsset[ref.asset] ??= await loadClip(ref.asset);
    clips[panel.id] = data;
  }
  return LoadedPanelManifest(manifest: manifest, clips: clips);
}
