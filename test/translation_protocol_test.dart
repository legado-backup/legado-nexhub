/// 共用翻译协议与校验的单元测试：
/// - [IdTranslationProtocol]：编号对位、分隔符容错、缺号/重号/越界；
/// - [TranslationFaithfulness]：拒答、原文回显、目标语言脚本、覆盖率；
/// - [TranslationException]：HTTP 错误分类与 Retry-After。
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/ai/id_translation_protocol.dart';
import 'package:nexhub/core/ai/translation_exception.dart';
import 'package:nexhub/core/ai/translation_faithfulness.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart';

VisionTextSegment _seg(String text, String translation) =>
    VisionTextSegment(text: text, translation: translation);

void main() {
  group('IdTranslationProtocol 编码', () {
    test('顺序编码从 1 开始并压平换行', () {
      final encoded = IdTranslationProtocol.encode(
        <String>['こんにちは\n元気？', 'ありがとう'],
      );
      expect(encoded, '1|こんにちは 元気？\n2|ありがとう');
    });

    test('encodeMap 按编号排序并可只编码部分编号', () {
      final encoded = IdTranslationProtocol.encodeMap(<int, String>{
        7: 'seven',
        3: 'three',
        5: '',
      });
      expect(encoded, '3|three\n7|seven');
    });
  });

  group('IdTranslationProtocol 解析', () {
    test('标准输出完整解析', () {
      final r = IdTranslationProtocol.parseSequential(
        '1|你好\n2|再见\n3|谢谢',
        3,
      );
      expect(r.isComplete, isTrue);
      expect(r.translations, <int, String>{1: '你好', 2: '再见', 3: '谢谢'});
      expect(r.missingIds, isEmpty);
    });

    test('乱序编号按编号对位而不是按行序', () {
      final r = IdTranslationProtocol.parseSequential(
        '2|第二条\n1|第一条\n3|第三条',
        3,
      );
      expect(r.translations[1], '第一条');
      expect(r.translations[2], '第二条');
      expect(r.translations[3], '第三条');
      expect(r.isComplete, isTrue);
    });

    test('容忍常见分隔符与编号包裹', () {
      const raw = '- **1|甲**\n'
          '[2]: 乙\n'
          '(3) 丙\n'
          '4：丁\n'
          '5、戊\n'
          '6）己\n'
          '7 - 庚\n'
          '8 → 辛';
      final r = IdTranslationProtocol.parseSequential(raw, 8);
      expect(r.isComplete, isTrue);
      expect(r.translations[8], '辛');
      expect(r.translations[1], '甲');
    });

    test('小数/版本号不会被误判为编号', () {
      final r = IdTranslationProtocol.parseSequential('1.5 meters\n2|第二', 2);
      expect(r.translations.containsKey(1), isFalse);
      expect(r.missingIds, <int>[1]);
      expect(r.translations[2], '第二');
    });

    test('缺号、重号、越界号分别记录', () {
      final r = IdTranslationProtocol.parseSequential(
        '1|甲\n1|甲重复\n3|丙\n9|越界',
        3,
      );
      expect(r.translations[1], '甲');
      expect(r.translations[3], '丙');
      expect(r.missingIds, <int>[2]);
      expect(r.duplicateIds, <int>[1]);
      expect(r.unknownIds, <int>[9]);
      expect(r.isComplete, isFalse);
      expect(r.hasStructureIssues, isTrue);
    });

    test('空译文视为缺失，不用空串占位', () {
      final r = IdTranslationProtocol.parseSequential('1|\n2|   ', 2);
      expect(r.translations, isEmpty);
      expect(r.missingIds, <int>[1, 2]);
    });

    test('定向重试可只期望缺失编号', () {
      final r = IdTranslationProtocol.parse(
        '3|丙\n7|庚',
        expectedIds: <int>[3, 7],
      );
      expect(r.isComplete, isTrue);
      expect(r.translations, <int, String>{3: '丙', 7: '庚'});
    });

    test('剥 markdown 围栏与前后杂文', () {
      const raw = '好的，结果如下：\n```text\n1|甲\n2|乙\n```\n以上。';
      final r = IdTranslationProtocol.parseSequential(raw, 2);
      expect(r.isComplete, isTrue);
    });

    test('describeIssues 汇总问题', () {
      final r = IdTranslationProtocol.parseSequential('1|甲\n1|甲\n9|x', 2);
      final desc = IdTranslationProtocol.describeIssues(r);
      expect(desc, contains('缺少编号 2'));
      expect(desc, contains('重复编号 1'));
      expect(desc, contains('越界编号 9'));
    });
  });

  group('TranslationFaithfulness 拒答', () {
    test('中文元话语拒答', () {
      expect(
        TranslationFaithfulness.looksLikeRefusal('抱歉，我无法翻译这张图片中的文字。'),
        isTrue,
      );
      expect(
        TranslationFaithfulness.looksLikeRefusal('作为AI，我无法处理该请求。'),
        isTrue,
      );
    });

    test('英文元话语拒答', () {
      expect(
        TranslationFaithfulness.looksLikeRefusal(
          "I'm sorry, but I can't translate this image.",
        ),
        isTrue,
      );
      expect(
        TranslationFaithfulness.looksLikeRefusal(
          'As an AI, I am unable to process this request.',
        ),
        isTrue,
      );
    });

    test('普通对话中的抱歉/无法不误判', () {
      expect(TranslationFaithfulness.looksLikeRefusal('抱歉，我来晚了。'), isFalse);
      expect(TranslationFaithfulness.looksLikeRefusal('我无法相信这是真的。'), isFalse);
      expect(TranslationFaithfulness.looksLikeRefusal('I am sorry for your loss.'), isFalse);
    });
  });

  group('TranslationFaithfulness 脚本与回显', () {
    test('原文回显命中（忽略标点空白）', () {
      expect(
        TranslationFaithfulness.isSourceEcho('Hello, world!', ' hello world '),
        isTrue,
      );
    });

    test('短文本回显豁免', () {
      expect(TranslationFaithfulness.isSourceEcho('OK', 'OK'), isFalse);
      expect(TranslationFaithfulness.isSourceEcho('BGM', 'BGM'), isFalse);
    });

    test('中文目标拦截整句日文/英文', () {
      expect(
        TranslationFaithfulness.wrongTargetScript('これはテストです', '中文'),
        isTrue,
      );
      expect(
        TranslationFaithfulness.wrongTargetScript('I do not know what you mean', '中文'),
        isTrue,
      );
      expect(
        TranslationFaithfulness.wrongTargetScript('这是测试', '中文'),
        isFalse,
      );
      expect(TranslationFaithfulness.wrongTargetScript('OK', '中文'), isFalse);
    });

    test('英文目标拦截中文残留', () {
      expect(
        TranslationFaithfulness.wrongTargetScript('这是中文', '英文'),
        isTrue,
      );
      expect(
        TranslationFaithfulness.wrongTargetScript('This is English', '英文'),
        isFalse,
      );
    });

    test('日文目标要求假名', () {
      expect(TranslationFaithfulness.wrongTargetScript('这是中文', '日文'), isTrue);
      expect(
        TranslationFaithfulness.wrongTargetScript('これはテストです', '日文'),
        isFalse,
      );
    });
  });

  group('TranslationFaithfulness 覆盖率', () {
    test('CJK 源文本低于 25% 判为截断', () {
      expect(
        TranslationFaithfulness.lowCoverage('これはとても長い台詞です。', '短'),
        isTrue,
      );
    });

    test('非 CJK 源文本低于 20% 判为截断', () {
      expect(
        TranslationFaithfulness.lowCoverage(
          'I understand what you mean.',
          'Yes.',
        ),
        isTrue,
      );
    });

    test('正常长度与短源文本不误判', () {
      expect(
        TranslationFaithfulness.lowCoverage(
          'I understand what you mean.',
          '我明白你的意思。',
        ),
        isFalse,
      );
      expect(TranslationFaithfulness.lowCoverage('Hi', '嗨'), isFalse);
    });
  });

  group('TranslationFaithfulness 整页', () {
    test('单条瑕疵不触发两阶段，保留其余译文', () {
      final result = TranslationFaithfulness.validatePage(
        <VisionTextSegment>[
          _seg('おはよう', '早上好'),
          _seg('ありがとう', '谢谢'),
          _seg('これはテストです', 'これはテストです'),
          _seg('さようなら', '再见'),
        ],
        '中文',
      );
      expect(result.accepted, hasLength(3));
      expect(result.issueCount, 1);
      expect(result.needsTwoPhase, isFalse);
      expect(result.issueIndexes, <int>[2]);
      expect(
        result.issues[2],
        contains(TranslationFaithfulnessIssue.sourceEcho),
      );
    });

    test('两条以上且比例达到 25% 触发两阶段', () {
      final result = TranslationFaithfulness.validatePage(
        <VisionTextSegment>[
          _seg('おはよう', '早上好'),
          _seg('ありがとう', ''),
          _seg('これはテストです', 'これはテストです'),
          _seg('さようなら', '再见'),
        ],
        '中文',
      );
      expect(result.issueCount, 2);
      expect(result.issueRatio, 0.5);
      expect(result.needsTwoPhase, isTrue);
    });

    test('全部无效时触发两阶段', () {
      final result = TranslationFaithfulness.validatePage(
        <VisionTextSegment>[_seg('おはよう', 'おはよう')],
        '中文',
      );
      expect(result.accepted, isEmpty);
      expect(result.needsTwoPhase, isTrue);
    });

    test('空页视为干净结果', () {
      final result =
          TranslationFaithfulness.validatePage(const <VisionTextSegment>[], '中文');
      expect(result.isClean, isTrue);
      expect(result.needsTwoPhase, isFalse);
    });
  });

  group('TranslationException 分类', () {
    DioException dio(int status,
        {Map<String, dynamic>? data, Map<String, List<String>>? headers}) {
      final options = RequestOptions(path: '/chat/completions');
      return DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response<dynamic>(
          requestOptions: options,
          statusCode: status,
          data: data,
          headers: headers == null ? null : Headers.fromMap(headers),
        ),
      );
    }

    test('401/403 认证失败且不切换端点', () {
      for (final status in <int>[401, 403]) {
        final e = TranslationException.from(dio(status));
        expect(e.kind, TranslationKind.auth);
        expect(e.isEndpointSwitchable, isFalse);
      }
    });

    test('402/额度错误归类为额度不足', () {
      final e = TranslationException.from(dio(402));
      expect(e.kind, TranslationKind.quota);
      expect(e.isEndpointSwitchable, isTrue);
      final e2 = TranslationException.from(dio(429, data: <String, dynamic>{
        'error': <String, dynamic>{
          'message': 'You exceeded your current quota',
          'code': 'insufficient_quota',
        },
      }));
      expect(e2.kind, TranslationKind.quota);
    });

    test('429 限流并解析 Retry-After', () {
      final e = TranslationException.from(dio(
        429,
        data: <String, dynamic>{
          'error': <String, dynamic>{'message': 'rate limit reached'},
        },
        headers: <String, List<String>>{
          'retry-after': <String>['30'],
        },
      ));
      expect(e.kind, TranslationKind.rateLimit);
      expect(e.retryAfter, const Duration(seconds: 30));
      expect(e.isEndpointSwitchable, isTrue);
    });

    test('5xx 服务端错误可切换', () {
      final e = TranslationException.from(dio(503));
      expect(e.kind, TranslationKind.server);
      expect(e.isEndpointSwitchable, isTrue);
      // 错误页正文含 authentication 不应被误判为不可切换的认证失败。
      final e2 = TranslationException.from(dio(503, data: <String, dynamic>{
        'error': <String, dynamic>{'message': 'authentication backend unavailable'},
      }));
      expect(e2.kind, TranslationKind.server);
      expect(e2.isEndpointSwitchable, isTrue);
    });

    test('普通 4xx 不切换', () {
      final e = TranslationException.from(dio(400, data: <String, dynamic>{
        'error': <String, dynamic>{'message': 'bad request'},
      }));
      expect(e.kind, TranslationKind.other);
      expect(e.isEndpointSwitchable, isFalse);
      expect(e.message, contains('bad request'));
    });

    test('连接错误/超时分类', () {
      final options = RequestOptions(path: '/chat/completions');
      final conn = TranslationException.from(DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: const SocketExceptionStub(),
      ));
      expect(conn.kind, TranslationKind.connection);
      final timeout = TranslationException.from(DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
      ));
      expect(timeout.kind, TranslationKind.timeout);
    });

    test('已有的 TranslationException 原样返回', () {
      const original = TranslationException('自定义', kind: TranslationKind.refusal);
      expect(
        TranslationException.from(original),
        same(original),
      );
    });

    test('空返回/格式异常归为 invalidResponse', () {
      expect(
        TranslationException.from(Exception('AI 返回内容为空')).kind,
        TranslationKind.invalidResponse,
      );
      expect(
        TranslationException.from(Exception('翻译返回格式异常')).kind,
        TranslationKind.invalidResponse,
      );
    });

    test('拒答文本归为 refusal', () {
      expect(
        TranslationException.from(Exception('content policy violation')).kind,
        TranslationKind.refusal,
      );
    });
  });
}

/// `dart:io` 的 SocketException 在测试里只需一个可识别文本。
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();

  @override
  String toString() => 'SocketException: Failed host lookup';
}
