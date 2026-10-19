/// Bing / AI 引擎选择策略。
library;

enum TranslationEngineOrder { bingFirst, aiFirst }

abstract final class TranslationEnginePolicy {
  /// 高级选项（术语表 / 非标准风格 / CoT）只能由 AI 正确执行。
  static bool advanced({
    required bool hasGlossary,
    required bool nonStandardStyle,
    required bool cot,
  }) =>
      hasGlossary || nonStandardStyle || cot;

  static TranslationEngineOrder order({
    required bool bingEnabled,
    required bool preferBing,
    required bool advancedOptions,
  }) {
    if (!bingEnabled || advancedOptions || !preferBing) {
      return TranslationEngineOrder.aiFirst;
    }
    return TranslationEngineOrder.bingFirst;
  }
}
