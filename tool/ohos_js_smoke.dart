// 鸿蒙 JS 沙箱冒烟用例（开发期临时入口，不随应用功能发布）。
//
// 运行：
//   flutter run -t tool/ohos_js_smoke.dart -d <deviceId>
//
// 覆盖 4 项能力（对应 lib/core/js 的运行时抽象）：
//   1. 同步 evaluate（书源 ScriptResolver 的核心路径）
//   2. var 注入 + 全局状态跨 evaluate 持久（书源脚本的状态模型）
//   3. sendMessage 桥接（书源 ctx.http.get 的消息通道）
//   4. Promise 微任务泵（.then 链在每次求值后推进；鸿蒙桥特有验证点）
import 'package:flutter/material.dart';
import 'package:nexhub/core/js/js_runtime.dart';
import 'package:nexhub/core/js/js_runtime_factory.dart';

void main() {
  runApp(const _SmokeApp());
}

class _SmokeApp extends StatefulWidget {
  const _SmokeApp({super.key});

  @override
  State<_SmokeApp> createState() => _SmokeAppState();
}

class _SmokeAppState extends State<_SmokeApp> {
  final List<String> _lines = <String>[];
  late final NexJsRuntime _runtime;

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _log(String line) {
    debugPrint('[JSSmoke] $line');
    setState(() => _lines.add(line));
  }

  void _run() {
    try {
      _runtime = createJsRuntime();
      _log('runtime: ${_runtime.runtimeType}');

      // 1. 同步求值
      final r1 = _runtime.evaluate('1 + 2');
      _log('① 1+2 => "${r1.stringResult}" ${r1.isError ? "[ERR ${r1.stringResult}]" : ""}');

      // 2. 全局变量跨求值持久
      _runtime.evaluate('var __smoke = "n" + "exhub";');
      final r2 = _runtime.evaluate('__smoke');
      _log('② 全局变量 => "${r2.stringResult}"');

      // 3. 桥接消息（sendMessage → Dart 回调）
      String? bridged;
      _runtime.onMessage('flutterBridge', (message) {
        bridged = '$message';
        _log('③ bridge 收到 => $bridged');
      });
      final r3 = _runtime.evaluate(
        'sendMessage("flutterBridge", '
        'JSON.stringify({method:"httpGet",args:["https://example.com"],id:"t1"})); '
        '"sent"',
      );
      _log('③ 发送结果 => "${r3.stringResult}"');

      // 4. Promise 微任务泵：.then 回调应在本次求值结束时已执行
      _runtime.evaluate(
        'var __smokeAsync = null; '
        'Promise.resolve(42).then(function(v){ __smokeAsync = v; });',
      );
      final r4 = _runtime.evaluate('String(__smokeAsync)');
      _log('④ Promise 泵 => "${r4.stringResult}"（期望 42）');

      _runtime.dispose();
      _log('== 冒烟结束 ==');
    } on Object catch (e) {
      _log('异常: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('JS 沙箱冒烟')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: _lines
              .map((l) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(l),
                  ))
              .toList(),
        ),
      ),
    );
  }
}
