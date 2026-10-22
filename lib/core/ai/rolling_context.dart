/// 滚动翻译上下文（纯内存，可从缓存重建）。
///
/// 保留最近若干段原文+译文，渲染时只取尾部若干段注入提示词：
/// - 块与块、章与章之间保持指代、语气与人名译名连续；
/// - 保留量远大于注入量，续跑时无需重新请求已译段落即可复原语境；
/// - 按段数与字符双重封顶，避免长段落把提示词预算吃光。
library;

import 'vision_translation_client.dart' show TranslationContextPair;

class RollingContext {
  RollingContext({
    this.maxRetained = 40,
    this.renderPairs = 12,
    this.maxChars = 2000,
    Iterable<TranslationContextPair> seed = const <TranslationContextPair>[],
  }) {
    addAll(seed);
  }

  /// 内存中保留的最大段数（超出丢弃最早段）。
  final int maxRetained;

  /// 渲染时最多注入的段数。
  final int renderPairs;

  /// 渲染时原文+译文总字符上限（至少保留最后一段，便于断句衔接）。
  final int maxChars;

  final List<TranslationContextPair> _pairs = <TranslationContextPair>[];

  bool get isEmpty => _pairs.isEmpty;
  int get length => _pairs.length;

  void add(String source, String translation) {
    final s = source.trim();
    final t = translation.trim();
    if (s.isEmpty || t.isEmpty) return;
    _pairs.add((source: s, translation: t));
    if (_pairs.length > maxRetained) {
      _pairs.removeRange(0, _pairs.length - maxRetained);
    }
  }

  void addAll(Iterable<TranslationContextPair> pairs) {
    for (final p in pairs) {
      add(p.source, p.translation);
    }
  }

  void clear() => _pairs.clear();

  /// 尾部待注入段（从最后一段向前累计，按段数与字符封顶后正序返回）。
  List<TranslationContextPair> render() {
    final picked = <TranslationContextPair>[];
    var chars = 0;
    for (var i = _pairs.length - 1; i >= 0 && picked.length < renderPairs; i--) {
      final p = _pairs[i];
      final cost = p.source.length + p.translation.length;
      if (picked.isNotEmpty && chars + cost > maxChars) break;
      picked.add(p);
      chars += cost;
    }
    return picked.reversed.toList(growable: false);
  }

  /// 从已缓存译文重建（原文与译文按位对齐，任一为空则跳过）。
  static RollingContext fromCache({
    List<String>? sources,
    List<String>? translations,
    int maxRetained = 40,
    int renderPairs = 12,
    int maxChars = 2000,
  }) {
    final ctx = RollingContext(
      maxRetained: maxRetained,
      renderPairs: renderPairs,
      maxChars: maxChars,
    );
    if (sources == null || translations == null) return ctx;
    final n = sources.length < translations.length
        ? sources.length
        : translations.length;
    for (var i = 0; i < n; i++) {
      ctx.add(sources[i], translations[i]);
    }
    return ctx;
  }
}
