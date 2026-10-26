/// 倾斜相位计算（纯 Dart，无 Flutter 依赖，可独立单测）。
///
/// 由加速度计（含重力）三轴读数近似设备倾斜角，再按 [maxTiltRad] 归一化到
/// [-1, 1] 相位。这是参考实现：阅读场景手机接近竖直握持时读数最稳定；
/// 平放时重力主要落在 Z 轴，倾斜灵敏度下降（嵌入方可在 UI 上提示）。
library;

import 'dart:math' as math;

/// 由加速度三轴（m/s²，含重力）计算归一化倾斜相位。
///
/// 返回 `(phaseX, phaseY)`：
/// - `phaseX` 来自 roll = atan2(ax, az)（左右倾斜）；
/// - `phaseY` 来自 pitch = atan2(ay, √(ax² + az²))（前后倾斜）；
/// - 两者均除以 [maxTiltRad] 后钳制到 [-1, 1]。
(double, double) tiltToPhase({
  required double ax,
  required double ay,
  required double az,
  required double maxTiltRad,
}) {
  if (maxTiltRad <= 0) {
    throw ArgumentError('maxTiltRad must be > 0, got $maxTiltRad');
  }
  final roll = math.atan2(ax, az);
  final pitch = math.atan2(ay, math.sqrt(ax * ax + az * az));
  return (
    (roll / maxTiltRad).clamp(-1.0, 1.0).toDouble(),
    (pitch / maxTiltRad).clamp(-1.0, 1.0).toDouble(),
  );
}

/// 度转弧度（便捷）。
double degToRad(double deg) => deg * math.pi / 180.0;
