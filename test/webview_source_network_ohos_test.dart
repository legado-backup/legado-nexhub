// 鸿蒙源 WebView 网络跟随的代理规则 URL 单测。
//
// 覆盖 Android `[scheme=]host[:port]` 与鸿蒙 `[scheme://]host[:port]`
// 两套语法，避免 socks5 规则在任一平台被静默忽略。
//
// 说明：测试只导入无 Flutter/插件依赖的纯函数文件（本分支的
// flutter_inappwebview 是鸿蒙分叉，官方 SDK 下无法编译）。ProxyController
// 的通道下发与真机生效由 OHOS 静态分析与鸿蒙真机验证覆盖。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/network/runtime/webview_proxy_rule.dart';

void main() {
  group('代理规则 URL 平台语法', () {
    test('HTTP：Android 裸 host:port，鸿蒙显式 http://', () {
      expect(
        webviewProxyRuleUrl('1.2.3.4', 7890, ohos: false),
        '1.2.3.4:7890',
      );
      expect(
        webviewProxyRuleUrl('1.2.3.4', 7890, ohos: true),
        'http://1.2.3.4:7890',
      );
    });

    test('SOCKS5：Android 用 socks5=，鸿蒙用 socks5://', () {
      expect(
        webviewProxyRuleUrl(
          '1.2.3.4',
          1080,
          ohos: false,
          socks5: true,
        ),
        'socks5=1.2.3.4:1080',
      );
      expect(
        webviewProxyRuleUrl(
          '1.2.3.4',
          1080,
          ohos: true,
          socks5: true,
        ),
        'socks5://1.2.3.4:1080',
      );
    });

    test('本地正向代理：鸿蒙带 http://，Android 保持裸地址', () {
      expect(
        webviewProxyRuleUrl('127.0.0.1', 18975, ohos: true),
        'http://127.0.0.1:18975',
      );
      expect(
        webviewProxyRuleUrl('127.0.0.1', 18975, ohos: false),
        '127.0.0.1:18975',
      );
    });
  });
}
