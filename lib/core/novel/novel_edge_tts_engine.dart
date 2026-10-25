/// Edge 在线 TTS 引擎（微软 Edge 浏览器「大声朗读」接口）。
///
/// 走 WSS 协议直连 `speech.platform.bing.com`，输出 MP3 字节，实现与
/// 自定义 HTTP TTS 相同的 [TtsSynthesisEngine] 接口——播放层
/// （[NovelHttpTtsPlayer]）、音频缓存、多角色路由全部复用，仅合成
/// 通道不同。
///
/// 协议要点（与 edge-tts 社区实现一致）：
/// - 连接 URL 携带固定 `TrustedClientToken` 与按 5 分钟窗口生成的
///   `Sec-MS-GEC` DRM 令牌（SHA-256，算法见 [_secMsGec]）；
/// - 连接后先发 `speech.config`（输出格式 audio-24khz-48kbitrate-mono-mp3
///   ，关闭边界元数据），再发 `ssml` 请求（X-RequestId 头 + SSML 体）；
/// - 文本帧为 JSON 状态（`turn.end` 表示结束），二进制帧为
///   `2 字节 header 长度 + header + MP3 分片`（header 含 `Path:audio`）；
/// - 逐分片拼接，`turn.end` 后整段 MP3 返回。
///
/// 音色为固定内置表（[kEdgeTtsVoices]）；语速映射为 SSML `+N%` 格式。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';

import 'novel_edge_tts_drm.dart';
import 'novel_http_tts_engine.dart';
import 'novel_tts_audio_cache.dart';

/// Edge TTS 固定客户端令牌（Edge 浏览器「大声朗读」功能公开常量）。
const String _kTrustedClientToken =
    '6A5AA1D4EAFF4E9FB37E23D68491D6F4';

/// 连接 URL 中的 Edge 版本标记（v2 DRM 对应 143 系列）。
const String _kGecVersion = '2-143.0.3650.75';

/// Edge 模式未指定音色时的默认音色（引擎内部回退同款）。
const String kEdgeTtsDefaultVoice = 'zh-CN-XiaoxiaoNeural';

/// 内置 Edge 音色（voice id → 显示名）。
///
/// 精选中文主流音色 + 英/日常用，避免上百条全量列表的噪音；
/// 用户也可在音色字段手填任意 Edge voice id。
const Map<String, String> kEdgeTtsVoices = <String, String>{
  'zh-CN-XiaoxiaoNeural': '晓晓（女·温暖）',
  'zh-CN-XiaoyiNeural': '晓伊（女·活泼）',
  'zh-CN-YunjianNeural': '云健（男·沉稳）',
  'zh-CN-YunxiNeural': '云希（男·阳光）',
  'zh-CN-YunxiaNeural': '云夏（男·少年）',
  'zh-CN-YunyangNeural': '云扬（男·新闻）',
  'zh-CN-liaoning-XiaobeiNeural': '晓北（东北）',
  'zh-CN-shaanxi-XiaoniNeural': '晓妮（陕西）',
  'zh-TW-HsiaoChenNeural': '曉臻（台湾）',
  'zh-HK-HiuMaanNeural': '曉曼（粤语）',
  'en-US-AriaNeural': 'Aria (EN female)',
  'en-US-GuyNeural': 'Guy (EN male)',
  'ja-JP-NanamiNeural': '七海（日语）',
};

/// Edge 在线合成引擎（实现 [TtsSynthesisEngine]）。
class EdgeTtsSynthesisEngine implements TtsSynthesisEngine {
  EdgeTtsSynthesisEngine({this.rate = 1.0, this.cache});

  /// 语速（0.5-2.0，映射 SSML ±% 并参与缓存键）。
  final double rate;

  /// 音频文件缓存（null = 不缓存）。
  final TtsAudioFileCache? cache;

  /// 单次合成的总时限（握手 + 合成 + 收流）。
  static const Duration _timeout = Duration(seconds: 30);

  @override
  Future<TtsSynthesisResult> synthesize({
    required String text,
    required String voice,
    required String role,
  }) async {
    if (text.trim().isEmpty) {
      return TtsSynthesisResult(bytes: null, role: role);
    }
    final resolvedVoice =
        voice.trim().isEmpty ? kEdgeTtsDefaultVoice : voice.trim();
    final rateLabel = rate.toStringAsFixed(1);
    final key = TtsAudioFileCache.keyFor(
      urlTemplate: 'edge-tts://$resolvedVoice',
      voice: resolvedVoice,
      rate: rateLabel,
      text: text,
    );
    final cached = await cache?.read(key);
    if (cached != null) {
      return TtsSynthesisResult(bytes: cached, role: role);
    }
    try {
      final bytes =
          await _synthesizeOnce(text, resolvedVoice).timeout(_timeout);
      if (bytes != null && bytes.isNotEmpty) {
        await cache?.write(key, bytes);
        return TtsSynthesisResult(bytes: bytes, role: role);
      }
      return TtsSynthesisResult(bytes: null, role: role);
    } on Object {
      return TtsSynthesisResult(bytes: null, role: role);
    }
  }

  /// Sec-MS-GEC v2 DRM 令牌（生成见 [novel_edge_tts_drm.dart]）。
  static String secMsGec() => generateEdgeSecMsGecV2();

  /// 32 位 hex 连接 id（仅要求连接内唯一，服务端不校验格式）。
  static String _connectionId() {
    final rnd = DateTime.now().microsecondsSinceEpoch;
    final a = (rnd % 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    final b = ((rnd ~/ 7919) % 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    final c = ((rnd ~/ 104729) % 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    final d = ((rnd ~/ 15485863) % 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    return '$a$b$c$d';
  }

  static String _ssmlRate(double rate) {
    if (rate <= 0) return '+0%';
    final pct = ((rate - 1.0) * 100).round();
    return pct >= 0 ? '+$pct%' : '$pct%';
  }

  /// 一次完整合成：建连 → 发配置与 SSML → 收流拼 MP3 → 关闭。
  Future<Uint8List?> _synthesizeOnce(String text, String voice) async {
    final connectionId = _connectionId();
    final uri = Uri.parse(
        'wss://speech.platform.bing.com/consumer/speech/synthesize/'
        'readaloud/edge/v1?TrustedClientToken=$_kTrustedClientToken'
        '&Sec-MS-GEC=${secMsGec()}&Sec-MS-GEC-Version=$_kGecVersion'
        '&ConnectionId=$connectionId');
    final ws = IOWebSocketChannel.connect(
      uri,
      customClient: HttpClient()
        // dart:io 的 WebSocket 会给 Upgrade 请求追加默认 UA
        // （"Dart/x (dart:io), <自定义>"），服务端 WAF 见 Dart 前缀直接
        // 403——预设单一 Edge UA 覆盖之。
        ..userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
      headers: <String, String>{
        // 模拟 Edge 浏览器「大声朗读」来源（服务端校验 Origin/MUID）。
        'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
        'Accept-Language': 'en-US,en;q=0.9',
        'Cookie': 'muid=${generateEdgeMuid()};',
      },
    );
    try {
      await ws.ready.timeout(const Duration(seconds: 15));
      final timestamp =
          DateTime.now().toUtc().toIso8601String().split('.').first;

      // 1) speech.config：输出格式 + 关闭句/词边界元数据。
      const configMsg = 'X-Timestamp:PLACEHOLDER\r\n'
          'Content-Type:application/json; charset=utf-8\r\n'
          'Path:speech.config\r\n\r\n'
          '{"context":{"synthesis":{"audio":{"metadataoptions":'
          '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
          '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}';
      ws.sink.add(configMsg.replaceFirst('PLACEHOLDER', timestamp));

      // 2) SSML 合成请求（文本做 XML 转义，& 先于 < >）。
      final escaped = text
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');
      final ssml =
          "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
          "xml:lang='zh-CN'><voice name='$voice'>"
          "<prosody pitch='+0Hz' rate='${_ssmlRate(rate)}' volume='+0%'>"
          '$escaped</prosody></voice></speak>';
      ws.sink.add('X-RequestId:$connectionId\r\n'
          'Content-Type:application/ssml+xml\r\n'
          'X-Timestamp:${timestamp}Z\r\n'
          'Path:ssml\r\n\r\n'
          '$ssml');

      // 3) 收流：text 帧看 turn.end，binary 帧拼 MP3。
      final audio = BytesBuilder(copy: false);
      await for (final frame in ws.stream) {
        if (frame is String) {
          if (frame.contains('Path:turn.end')) break;
          continue;
        }
        final data = frame is Uint8List
            ? frame
            : frame is List<int>
                ? Uint8List.fromList(frame)
                : null;
        if (data == null || data.length < 2) continue;
        final headerLen = (data[0] << 8) | data[1];
        if (data.length < 2 + headerLen) continue;
        final header =
            utf8.decode(data.sublist(2, 2 + headerLen), allowMalformed: true);
        if (header.contains('Path:audio')) {
          audio.add(data.sublist(2 + headerLen));
        }
      }
      return audio.isEmpty ? null : audio.takeBytes();
    } finally {
      await ws.sink.close();
    }
  }
}
