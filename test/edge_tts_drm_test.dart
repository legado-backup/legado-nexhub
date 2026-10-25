/// Edge TTS v2 DRM 令牌对照测试（与 edge-tts 参照值逐一比对）。
/// 参照值由 edge-tts 7.3.1 `generate_sec_ms_gec_v2(<ts>)` 生成。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/novel/novel_edge_tts_drm.dart';

void main() {
  test('v2 token 与参照实现一致', () {
    // (unix秒, 参照令牌)
    const cases = <(int, String)>[
      (
        1792900000,
        'D80D1E568EC8365F-'
            'EF60689F9F8619A8C86FE5EB63D4936B9B166AFF53173BA6F7438D9925464962'
      ),
      (
        1792900135,
        'D80D1E568EC8365F-'
            'EF60689F9F8619A8C86FE5EB63D4936B9B166AFF53173BA6F7438D9925464962'
      ),
      (
        1343737350,
        '580DAF24C2361B26-'
            '3885007E63A149125B5A629DE20807403FDB0F75CF784D5CE80868A0E0C4DFF5'
      ),
      (
        1792899999,
        'D80D1E568EC8365F-'
            'EF60689F9F8619A8C86FE5EB63D4936B9B166AFF53173BA6F7438D9925464962'
      ),
    ];
    for (final (ts, expected) in cases) {
      final got = generateEdgeSecMsGecV2(unixTimestampMs: ts * 1000);
      expect(got, expected, reason: 'ts=$ts');
    }
  });

  test('MUID 为 32 位大写 hex', () {
    final muid = generateEdgeMuid();
    expect(muid.length, 32);
    expect(RegExp(r'^[0-9A-F]{32}$').hasMatch(muid), isTrue);
    expect(generateEdgeMuid(), isNot(muid));
  });
}
