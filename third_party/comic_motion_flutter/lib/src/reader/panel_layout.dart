/// 分格布局：把归一化分格矩形映射到互动层的局部坐标。
///
/// 宿主给出互动层自身矩形、页面图片尺寸与 `BoxFit`；本模块按 Flutter
/// 的 fit 语义算出页面显示矩形，再叠加 `quarterTurns` 旋转，最后提供
/// 命中测试。纯几何、无绘制，可脱离 widget 单测。
library;

import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/painting.dart' show BoxFit;

import 'panel_manifest.dart';

/// 一次布局结果。所有矩形都在互动层的局部坐标（左上原点）。
class PanelLayout {
  const PanelLayout({
    required this.availableRect,
    required this.pageRect,
    required this.panelRects,
  });

  /// 互动层自身矩形。
  final Rect availableRect;

  /// 图片在互动层内的显示矩形（可能溢出 availableRect，如 cover/fitWidth）。
  final Rect pageRect;

  /// panelId → 分格屏幕矩形（可能溢出于 availableRect）。
  final Map<String, Rect> panelRects;

  /// 解析布局。`imageSize` 必须为正。
  static PanelLayout resolve({
    required Rect availableRect,
    required Size imageSize,
    required List<PanelSpec> panels,
    BoxFit fit = BoxFit.contain,
    int quarterTurns = 0,
  }) {
    assert(imageSize.width > 0 && imageSize.height > 0,
        'imageSize must be positive');
    final int q = quarterTurns % 4;
    final Size displaySize = q.isOdd
        ? Size(imageSize.height, imageSize.width)
        : imageSize;
    final Rect pageRect = _fittedRect(displaySize, availableRect, fit);
    final Map<String, Rect> panelRects = <String, Rect>{};
    for (final panel in panels) {
      final Rect r = _rotateRect(panel.rect, q);
      panelRects[panel.id] = Rect.fromLTRB(
        pageRect.left + r.left * pageRect.width,
        pageRect.top + r.top * pageRect.height,
        pageRect.left + r.right * pageRect.width,
        pageRect.top + r.bottom * pageRect.height,
      );
    }
    return PanelLayout(
      availableRect: availableRect,
      pageRect: pageRect,
      panelRects: panelRects,
    );
  }

  /// 命中分格：点须在 [availableRect] 内；重叠取面积最小者，面积相同
  /// 取清单靠后者。未命中返回 null。
  String? hitTest(Offset localPosition) {
    if (!availableRect.contains(localPosition)) return null;
    String? best;
    double bestArea = double.infinity;
    for (final entry in panelRects.entries) {
      final Rect r = entry.value;
      if (!r.contains(localPosition)) continue;
      final double area = r.width * r.height;
      if (area <= bestArea) {
        best = entry.key;
        bestArea = area;
      }
    }
    return best;
  }

  static Rect _fittedRect(Size image, Rect box, BoxFit fit) {
    final double sx = box.width / image.width;
    final double sy = box.height / image.height;
    final (double w, double h) = switch (fit) {
      BoxFit.fill => (box.width, box.height),
      BoxFit.contain => sx < sy
          ? (box.width, image.height * sx)
          : (image.width * sy, box.height),
      BoxFit.cover => sx > sy
          ? (box.width, image.height * sx)
          : (image.width * sy, box.height),
      BoxFit.fitWidth => (box.width, image.height * sx),
      BoxFit.fitHeight => (image.width * sy, box.height),
      BoxFit.none => (image.width, image.height),
      BoxFit.scaleDown => sx > 1 && sy > 1
          ? (image.width, image.height)
          : sx < sy
              ? (box.width, image.height * sx)
              : (image.width * sy, box.height),
    };
    return Rect.fromLTWH(
      box.left + (box.width - w) / 2,
      box.top + (box.height - h) / 2,
      w,
      h,
    );
  }

  /// 源图归一化 rect → 显示方向归一化 rect（顺时针旋转）。
  static Rect _rotateRect(Rect r, int q) {
    return switch (q) {
      0 => r,
      1 => Rect.fromLTRB(1 - r.bottom, r.left, 1 - r.top, r.right),
      2 => Rect.fromLTRB(1 - r.right, 1 - r.bottom, 1 - r.left, 1 - r.top),
      _ => Rect.fromLTRB(r.top, 1 - r.right, r.bottom, 1 - r.left),
    };
  }
}
