/// 轻量 AI 文本请求客户端（术语提取 / 审校 / 精译等辅助调用）。
///
/// 与翻译主链路共用多端点失败路由（[AiEndpointRouter]），但只负责一次
/// system + user 的 chat/completions 请求，不维护会话历史；JSON 结果经
/// [LlmJson] 容错解析。调用方自行决定失败降级（辅助调用失败不应中断翻译）。
library;

import 'package:dio/dio.dart';

import 'endpoint_router.dart';
import 'llm_json.dart';
import 'translation_exception.dart';
import 'vision_translation_client.dart' show AiEndpointConfig;
import '../utils/app_log.dart';

class AiChatClient {
  AiChatClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// 发送一次对话请求并返回文本内容。
  Future<String> complete(
    List<AiEndpointConfig> endpoints, {
    required String system,
    required String user,
    double temperature = 0.1,
    int? maxTokens,
    Duration receiveTimeout = const Duration(seconds: 120),
  }) async {
    try {
      return await AiEndpointRouter.execute<String>(endpoints, (cfg) async {
        final trimmedBase =
            cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
        final resp = await _dio.post<Map<String, dynamic>>(
          '$trimmedBase/chat/completions',
          options: Options(
            headers: <String, dynamic>{
              'Content-Type': 'application/json',
              if (cfg.apiKey.trim().isNotEmpty)
                'Authorization': 'Bearer ${cfg.apiKey.trim()}',
            },
            sendTimeout: const Duration(seconds: 30),
            receiveTimeout: receiveTimeout,
          ),
          data: <String, dynamic>{
            'model': cfg.model.trim().isNotEmpty
                ? cfg.model.trim()
                : 'gpt-3.5-turbo',
            'messages': <Map<String, dynamic>>[
              <String, dynamic>{'role': 'system', 'content': system},
              <String, dynamic>{'role': 'user', 'content': user},
            ],
            'temperature': temperature,
            if (maxTokens != null) 'max_tokens': maxTokens,
          },
        );
        final choices = resp.data?['choices'] as List?;
        if (choices == null || choices.isEmpty) {
          throw const TranslationException('AI 返回内容为空');
        }
        final content =
            (choices.first['message'] as Map?)?['content'] as String?;
        if (content == null || content.trim().isEmpty) {
          throw const TranslationException('AI 返回内容为空');
        }
        return content;
      });
    } on Object catch (e) {
      AppLog.instance.w('[AI 辅助请求] 失败: $e');
      throw TranslationException.from(e);
    }
  }

  /// 发送一次对话请求并容错解析 JSON（数组或对象）；解析失败返回 null。
  Future<dynamic> completeJson(
    List<AiEndpointConfig> endpoints, {
    required String system,
    required String user,
    double temperature = 0.1,
    int? maxTokens,
    Duration receiveTimeout = const Duration(seconds: 120),
  }) async {
    final content = await complete(
      endpoints,
      system: system,
      user: user,
      temperature: temperature,
      maxTokens: maxTokens,
      receiveTimeout: receiveTimeout,
    );
    return LlmJson.tryDecode(content);
  }
}
