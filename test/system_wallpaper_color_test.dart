import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/theme/system_wallpaper_color.dart';

void main() {
  group('SystemWallpaperColor.fromRgba', () {
    test('合法的 [r,g,b,a] 转 ARGB Color', () {
      expect(
        SystemWallpaperColor.fromRgba(<Object?>[103, 80, 164, 255]),
        const Color(0xFF6750A4),
      );
    });

    test('长度不足 / 非整数 / 越界 / 全透明均视为不可用', () {
      expect(SystemWallpaperColor.fromRgba(null), isNull);
      expect(SystemWallpaperColor.fromRgba(<Object?>[1, 2, 3]), isNull);
      expect(
          SystemWallpaperColor.fromRgba(<Object?>[1, 2, 3, 255, 9]), isNotNull);
      expect(SystemWallpaperColor.fromRgba(<Object?>[1, 2, 3.0, 255]), isNull);
      expect(SystemWallpaperColor.fromRgba(<Object?>[1, 2, 256, 255]), isNull);
      expect(SystemWallpaperColor.fromRgba(<Object?>[-1, 2, 3, 255]), isNull);
      expect(SystemWallpaperColor.fromRgba(<Object?>[1, 2, 3, 0]), isNull);
    });
  });
}
