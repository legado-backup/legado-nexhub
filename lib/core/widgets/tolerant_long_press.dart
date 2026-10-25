/// 大容忍度长按手势（跨模块共享版）。
///
/// Flutter 默认 touch slop 仅 18 逻辑像素，手机上手指按住时的自然抖动即可
/// 超限——长按在手势竞技场被取消，表现为「长按无反应」。放宽到 40px 后
/// 抖动不再打断长按；真正的滑动位移通常远超 40px，仍由滚动/拖拽手势获胜。
///
/// 与 novel_reader_screen 内的同名私有实现同源；本次抽公共版供详情页
/// 翻译组件使用，阅读器侧后续迁移。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 放宽「接受前位移容忍度」的长按识别器。
class TolerantLongPressGestureRecognizer extends LongPressGestureRecognizer {
  TolerantLongPressGestureRecognizer({this.preAcceptTolerance = 40});

  /// 接受前允许的漂移上限（逻辑像素）。
  final double preAcceptTolerance;

  @override
  double? get preAcceptSlopTolerance => preAcceptTolerance;
}

/// 便捷容器：child 长按（大容忍）回调 [onLongPress]。
class TolerantLongPress extends StatelessWidget {
  const TolerantLongPress({
    super.key,
    required this.onLongPress,
    required this.child,
    this.behavior = HitTestBehavior.opaque,
  });

  final VoidCallback? onLongPress;
  final Widget child;
  final HitTestBehavior behavior;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: behavior,
      gestures: <Type, GestureRecognizerFactory>{
        TolerantLongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TolerantLongPressGestureRecognizer>(
          () => TolerantLongPressGestureRecognizer(),
          (TolerantLongPressGestureRecognizer instance) {
            instance.onLongPress = onLongPress;
          },
        ),
      },
      child: child,
    );
  }
}
