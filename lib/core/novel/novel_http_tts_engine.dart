/// 在线 HTTP TTS 引擎。
///
/// 职责（与播放解耦，核心逻辑可单测）：
/// - **模板渲染**：[renderUrl] 把 `{text}` / `{voice}` / `{rate}` 占位符
///   替换为实际值（文本 URL 编码防止非法字符破坏端点语义）；
/// - **单句合成**：[HttpTtsPreloader.synthesize] 按「音色」合成一句，
///   先查 [TtsAudioFileCache]（命中跳网络），未命中 GET 后回写缓存；
/// - **失败计数**：连续失败计数由播放层（[NovelHttpTtsPlayer]）维护，
///   本类只保证一次合成的结果与异常安全。
///
/// 播放层不在本引擎内：引擎产出「可播放音频字节」，由 TTS 控制器
/// 决定用 media_kit 还是其它播放器顺序播放。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'novel_http_tts_config.dart';
import 'novel_tts_audio_cache.dart';

/// 合成单句音频的请求结果。
class TtsSynthesisResult {
  /// 音频字节（合成成功）；null = 合成失败（应静音占位或停止）。
  final Uint8List? bytes;

  /// 对应句子的角色（用于日志/多角色调试）。
  final String role;

  const TtsSynthesisResult({required this.bytes, required this.role});
}

/// 单句合成引擎抽象（播放层依赖此接口，测试注入假实现）。
abstract class TtsSynthesisEngine {
  /// 合成一句；voice 为播放层路由解析后的最终音色 id。
  Future<TtsSynthesisResult> synthesize({
    required String text,
    required String voice,
    required String role,
  });
}

/// 在线 HTTP 合成引擎：模板渲染 + 文件缓存 + GET 字节。
class HttpTtsPreloader implements TtsSynthesisEngine {
  HttpTtsPreloader({
    required this.config,
    this.rate = 1.0,
    this.cache,
    Dio Function()? dioFactory,
  }) : _dioFactory = dioFactory ?? _defaultDio;

  final NovelHttpTtsConfig config;

  /// 语速（0.5-2.0；渲染进模板 {rate} 并参与缓存键）。
  final double rate;

  /// 音频文件缓存（null = 不缓存，纯网络）。
  final TtsAudioFileCache? cache;

  final Dio Function() _dioFactory;

  static Dio _defaultDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
      ));

  @override
  Future<TtsSynthesisResult> synthesize({
    required String text,
    required String voice,
    required String role,
  }) async {
    final rateLabel = rate.toStringAsFixed(1);
    final key = TtsAudioFileCache.keyFor(
      urlTemplate: config.urlTemplate,
      voice: voice,
      rate: rateLabel,
      text: text,
    );
    // 1) 缓存命中：跳过网络。
    final cached = await cache?.read(key);
    if (cached != null) {
      return TtsSynthesisResult(bytes: cached, role: role);
    }
    // 2) 网络合成。
    final url = renderUrl(
      template: config.urlTemplate,
      text: text,
      voice: voice,
      rate: rate,
    );
    final dio = _dioFactory();
    try {
      final resp = await dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes =
          resp.data == null ? null : Uint8List.fromList(resp.data!);
      if (bytes != null && bytes.isNotEmpty) {
        await cache?.write(key, bytes);
      }
      return TtsSynthesisResult(bytes: bytes, role: role);
    } on Object {
      return TtsSynthesisResult(bytes: null, role: role);
    } finally {
      dio.close(force: true);
    }
  }
}

/// 渲染 URL 模板：{text}（URL 编码） / {voice} / {rate}。
///
/// 未替换成功的占位符保持原样（便于用户排查模板错误）。
String renderUrl({
  required String template,
  required String text,
  String voice = '',
  double rate = 1.0,
}) {
  var out = template;
  if (template.isEmpty) return '';
  out = out.replaceAll('{text}', Uri.encodeQueryComponent(text));
  out = out.replaceAll('{voice}', Uri.encodeQueryComponent(voice));
  out = out.replaceAll('{rate}', rate.toStringAsFixed(1));
  return out;
}
