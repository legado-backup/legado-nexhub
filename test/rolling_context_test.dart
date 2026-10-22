import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/ai/rolling_context.dart';

void main() {
  group('RollingContext', () {
    test('超出保留上限时丢弃最早段', () {
      final ctx = RollingContext(maxRetained: 3);
      ctx
        ..add('原1', '译1')
        ..add('原2', '译2')
        ..add('原3', '译3')
        ..add('原4', '译4');
      expect(ctx.length, 3);
      expect(
        ctx.render().map((p) => p.source),
        <String>['原2', '原3', '原4'],
      );
    });

    test('渲染按段数封顶，取最新段并保持正序', () {
      final ctx = RollingContext(renderPairs: 2);
      for (var i = 1; i <= 5; i++) {
        ctx.add('原$i', '译$i');
      }
      expect(
        ctx.render().map((p) => p.translation),
        <String>['译4', '译5'],
      );
    });

    test('渲染按字符封顶，至少保留最后一段', () {
      final ctx = RollingContext(renderPairs: 12, maxChars: 10);
      ctx
        ..add('长' * 8, '长' * 8)
        ..add('短', '短');
      // 最后一段成本 2，往前第二段成本 16 超预算 → 只保留最后一段。
      expect(ctx.render().map((p) => p.source), <String>['短']);
      final single = RollingContext(renderPairs: 12, maxChars: 1)
        ..add('超' * 10, '长' * 10);
      expect(single.render(), hasLength(1));
    });

    test('空原文/空译文不入上下文；空白段落两端裁剪', () {
      final ctx = RollingContext()
        ..add('  ', '译')
        ..add('原', ' ')
        ..add('  原文  ', '  译文  ');
      expect(ctx.length, 1);
      expect(ctx.render().single.source, '原文');
      expect(ctx.render().single.translation, '译文');
    });

    test('fromCache 按位对齐并跳过缺失项', () {
      final ctx = RollingContext.fromCache(
        sources: <String>['原1', '原2', '', '原4', '多出的原文'],
        translations: <String>['译1', '', '译3', '译4'],
      );
      expect(
        ctx.render().map((p) => p.source),
        <String>['原1', '原4'],
      );
    });

    test('seed 直接初始化并遵循保留上限', () {
      final ctx = RollingContext(
        maxRetained: 2,
        seed: <({String source, String translation})>[
          (source: '原1', translation: '译1'),
          (source: '原2', translation: '译2'),
          (source: '原3', translation: '译3'),
        ],
      );
      expect(
        ctx.render().map((p) => p.source),
        <String>['原2', '原3'],
      );
    });
  });
}
