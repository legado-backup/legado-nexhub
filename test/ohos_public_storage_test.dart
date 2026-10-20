/// 鸿蒙公共下载目录（`nexhub/ohos_storage`）单测：
/// - 编码路径的 scheme / 分隔符 / 拼接与还原；
/// - [OhosDocFileSystem] 的写入分块、读取、列举与根目录删除守卫。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/download/ohos_doc_file_system.dart';
import 'package:nexhub/core/platform/ohos_public_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('nexhub/ohos_storage');
  final List<MethodCall> calls = <MethodCall>[];

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls.clear();
  });

  tearDown(() {
    messenger().setMockMethodCallHandler(channel, null);
  });

  group('编码路径', () {
    test('识别 scheme 并保留普通路径原样', () {
      expect(isOhosDocPath('ohosdoc:///storage/x/Download/com.app'), isTrue);
      expect(isOhosDocPath('/storage/x/Download/com.app'), isFalse);
      expect(isOhosDocPath('content://tree/a'), isFalse);
    });

    test('根编码与还原保持路径一致', () {
      const String plain = '/storage/Users/currentUser/Download/com.nexhub';
      final String encoded = encodeOhosDocRoot(plain);
      expect(encoded, 'ohosdoc://$plain');
      expect(ohosDocToPlainPath(encoded), plain);
    });

    test('首次拼接插入分隔符，后续拼接用斜杠', () {
      final String root = encodeOhosDocRoot('/storage/x/Download/com.app');
      final String first = ohosDocJoin(root, '漫画');
      final String second = ohosDocJoin(first, '作品');
      expect(first, '$root␟漫画');
      expect(second, '$root␟漫画/作品');
      expect(ohosDocToPlainPath(second), '/storage/x/Download/com.app/漫画/作品');
    });

    test('带分隔符的相对段还原为真实路径', () {
      expect(
        ohosDocToPlainPath('ohosdoc:///storage/x/Download/com.app␟a/b.png'),
        '/storage/x/Download/com.app/a/b.png',
      );
    });
  });

  group('OhosDocFileSystem', () {
    test('构造时把真实路径转成编码根', () {
      final fs = OhosDocFileSystem('/storage/x/Download/com.app');
      expect(fs.basePath, 'ohosdoc:///storage/x/Download/com.app');
    });

    test('writeBytes 按 1 MiB 分块并经写会话落盘', () async {
      messenger().setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        if (call.method == 'openWrite') return 'w1';
        return null;
      });

      final fs = OhosDocFileSystem('/storage/x/Download/com.app');
      final Uint8List bytes = Uint8List((1 << 20) + 512);
      await fs.writeBytes(fs.join(fs.basePath, 'a.bin'), bytes);

      expect(
        calls.map((MethodCall c) => c.method),
        <String>['openWrite', 'writeChunk', 'writeChunk', 'closeWrite'],
      );
      final Map<Object?, Object?> first =
          calls[1].arguments as Map<Object?, Object?>;
      final Map<Object?, Object?> second =
          calls[2].arguments as Map<Object?, Object?>;
      expect(first['id'], 'w1');
      expect((first['bytes'] as Uint8List).length, 1 << 20);
      expect((second['bytes'] as Uint8List).length, 512);
      expect(calls[0].arguments, <String, Object?>{
        'path': '/storage/x/Download/com.app/a.bin',
      });
    });

    test('writeBytes 失败时仍关闭写会话', () async {
      messenger().setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        if (call.method == 'openWrite') return 'w1';
        if (call.method == 'writeChunk') {
          throw PlatformException(code: 'write_failed');
        }
        return null;
      });

      final fs = OhosDocFileSystem('/storage/x/Download/com.app');
      await expectLater(
        fs.writeBytes(fs.join(fs.basePath, 'a.bin'), Uint8List(4)),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.last.method, 'closeWrite');
    });

    test('readBytes 直接返回原生字节', () async {
      messenger().setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return Uint8List.fromList(<int>[1, 2, 3]);
      });

      final fs = OhosDocFileSystem('/storage/x/Download/com.app');
      final Uint8List bytes =
          await fs.readBytes(fs.join(fs.basePath, 'a.txt'));
      expect(bytes, <int>[1, 2, 3]);
      expect(calls.single.arguments, <String, Object?>{
        'path': '/storage/x/Download/com.app/a.txt',
      });
    });

    test('listFiles 映射原生条目，文件路径返回空列表', () async {
      messenger().setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return <Object?>[
          <String, Object?>{'name': 'a.jpg', 'isDir': false, 'size': 3},
          <String, Object?>{'name': 'sub', 'isDir': true, 'size': 0},
        ];
      });

      final fs = OhosDocFileSystem('/storage/x/Download/com.app');
      expect(
        await fs.listFiles(fs.basePath),
        <String>['a.jpg', 'sub'],
      );

      messenger().setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        throw PlatformException(code: 'list_failed');
      });
      expect(
        await fs.listFiles(fs.join(fs.basePath, 'a.jpg')),
        isEmpty,
      );
    });

    test('delete 不删除授权根，嵌套路径走原生删除', () async {
      messenger().setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return null;
      });

      final fs = OhosDocFileSystem('/storage/x/Download/com.app');
      await fs.delete(fs.basePath);
      expect(calls, isEmpty);

      final String nested = fs.join(fs.basePath, '漫画/1.cbz');
      await fs.delete(nested);
      expect(calls.single.method, 'delete');
      expect(calls.single.arguments, <String, Object?>{
        'path': '/storage/x/Download/com.app/漫画/1.cbz',
      });
    });

    test('createDir 与 exists 转发真实路径', () async {
      messenger().setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        if (call.method == 'exists') return true;
        return null;
      });

      final fs = OhosDocFileSystem('/storage/x/Download/com.app');
      final String dir = fs.join(fs.basePath, 'Screenshots');
      await fs.createDir(dir);
      expect(await fs.exists(dir), isTrue);
      expect(
        calls.map((MethodCall c) => c.arguments),
        <Object?>[
          <String, Object?>{
            'path': '/storage/x/Download/com.app/Screenshots',
          },
          <String, Object?>{
            'path': '/storage/x/Download/com.app/Screenshots',
          },
        ],
      );
    });
  });
}
