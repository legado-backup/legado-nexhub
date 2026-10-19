/// WebView 代理规则 URL 的平台语法（纯函数，无 Flutter/插件依赖）。
///
/// Android 的 androidx ProxyConfig 规则格式为 `[scheme=]host[:port]`，
/// socks5 必须写成 `socks5=host:port`；鸿蒙 ArkWeb ProxyConfig 的格式为
/// `[scheme://]host[:port]`（flutter_inappwebview_ohos 对无 scheme 的值补
/// `http://`，这里显式给出，避免两套语法在调用点混用）。
///
/// 单独成文件是为了让宿主单测不依赖 OHOS 分叉的 flutter_inappwebview：
/// 该分叉在官方 SDK 下无法编译（`TargetPlatform.ohos` 不存在）。
library;

String webviewProxyRuleUrl(
  String host,
  int port, {
  required bool ohos,
  bool socks5 = false,
}) {
  if (ohos) {
    return socks5 ? 'socks5://$host:$port' : 'http://$host:$port';
  }
  return socks5 ? 'socks5=$host:$port' : '$host:$port';
}
