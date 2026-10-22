import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/ai/llm_json.dart';

void main() {
  group('LlmJson', () {
    test('解析纯 JSON 数组', () {
      final decoded = LlmJson.tryDecodeArray(
        '[{"term":"アリス","translation":"爱丽丝"}]',
      );
      expect(decoded, hasLength(1));
      expect((decoded!.first as Map)['translation'], '爱丽丝');
    });

    test('剥除 markdown 围栏后解析', () {
      final decoded = LlmJson.tryDecodeArray('''
```json
[
  {"term": "魔法", "translation": "法术"}
]
```
''');
      expect(decoded, hasLength(1));
      expect((decoded!.first as Map)['term'], '魔法');
    });

    test('截取前后说明文字中的最外层数组', () {
      final decoded = LlmJson.tryDecodeArray(
        '好的，结果如下：\n'
        '[{"term":"剣","translation":"剑"}]\n'
        '以上。',
      );
      expect(decoded, hasLength(1));
      expect((decoded!.first as Map)['term'], '剣');
    });

    test('字符串内的括号不影响配对', () {
      final decoded = LlmJson.tryDecodeArray(
        '[{"term":"[测试]","translation":"括号"}]',
      );
      expect(decoded, hasLength(1));
      expect((decoded!.first as Map)['term'], '[测试]');
    });

    test('对象与数组混合时按最外层数组解析', () {
      final decoded = LlmJson.tryDecodeArray(
        '{"note":"见下方","terms":[{"term":"王都","translation":"王都"}]}',
      );
      // 最外层是对象，tryDecodeArray 返回 null；tryDecode 可取对象。
      expect(decoded, isNull);
      final map = LlmJson.tryDecodeObject(
        '{"note":"见下方","terms":[{"term":"王都","translation":"王都"}]}',
      );
      expect(map?['terms'], hasLength(1));
    });

    test('非法输入返回 null', () {
      expect(LlmJson.tryDecode('完全不是 JSON'), isNull);
      expect(LlmJson.tryDecodeArray(''), isNull);
      expect(LlmJson.tryDecodeObject('[1,2,3]'), isNull);
    });
  });
}
