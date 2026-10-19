/// 可复用翻译文本组件（标题/标签就地替换，简介/评论原文+译文）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../ai/translation_exception.dart';
import '../ai/translation_feature_flags.dart';
import '../ai/translation_language.dart';
import '../ai/ui_text_translator.dart';

enum TranslatableTextKind { title, tag, summary, comment }

/// 就地显示译文（标题 / 标签）；长按切换原文或触发翻译。
class AutoTranslatedText extends StatefulWidget {
  const AutoTranslatedText({
    super.key,
    required this.text,
    this.kind = TranslatableTextKind.title,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String text;
  final TranslatableTextKind kind;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  State<AutoTranslatedText> createState() => _AutoTranslatedTextState();
}

class _AutoTranslatedTextState extends State<AutoTranslatedText> {
  final TranslationFeatureFlags _flags = TranslationFeatureFlags.instance;
  String? _targetLang;
  String? _translation;
  bool _showOriginal = false;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    _flags.addListener(_onFlags);
    unawaited(_flags.ensureLoaded());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final code = TranslationLanguage.preferredCodeForLocale(
      Localizations.localeOf(context),
    );
    if (code != _targetLang) {
      _targetLang = code;
      _translation = null;
      _showOriginal = false;
      _requested = false;
      _maybeAuto();
    }
  }

  @override
  void didUpdateWidget(covariant AutoTranslatedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.kind != widget.kind) {
      _translation = null;
      _showOriginal = false;
      _requested = false;
      _maybeAuto();
    }
  }

  @override
  void dispose() {
    _flags.removeListener(_onFlags);
    super.dispose();
  }

  void _onFlags() {
    if (!mounted) return;
    setState(() {});
    _maybeAuto();
  }

  bool get _autoEnabled => switch (widget.kind) {
        TranslatableTextKind.title => _flags.autoTitle,
        TranslatableTextKind.tag => _flags.autoTags,
        TranslatableTextKind.summary => _flags.autoSummary,
        TranslatableTextKind.comment => _flags.autoComments,
      };

  void _maybeAuto() {
    unawaited(_maybeAutoAsync());
  }

  Future<void> _maybeAutoAsync() async {
    if (!mounted || _requested || _translation != null) return;
    await _flags.ensureLoaded();
    if (!mounted || _requested || _translation != null) return;
    if (!_flags.bingEnabled || !_autoEnabled) return;
    final target = _targetLang;
    if (target == null) return;
    if (!TranslationLanguage.shouldTranslate(widget.text, target)) return;
    _requested = true;
    await _request(manual: false);
  }

  Future<void> _request({required bool manual}) async {
    final target = _targetLang;
    if (target == null) return;
    try {
      final translated = await UiTextTranslator.instance.translate(
        widget.text,
        targetLang: target,
        manual: manual,
      );
      if (!mounted || translated == null) return;
      setState(() {
        _translation = translated;
        _showOriginal = false;
      });
    } on Object catch (e) {
      if (!mounted || !manual) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(TranslationException.from(e).message)),
      );
    }
  }

  Future<void> _onLongPress() async {
    if (_translation != null) {
      setState(() => _showOriginal = !_showOriginal);
      return;
    }
    _requested = true;
    await _request(manual: true);
  }

  @override
  Widget build(BuildContext context) {
    final showTranslation = _translation != null && !_showOriginal;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: _onLongPress,
      child: Text(
        showTranslation ? _translation! : widget.text,
        style: widget.style,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
        textAlign: widget.textAlign,
      ),
    );
  }
}

/// 原文保留，译文以次要样式追加在下方（简介 / 评论）。
class BilingualTranslatedText extends StatefulWidget {
  const BilingualTranslatedText({
    super.key,
    required this.text,
    this.kind = TranslatableTextKind.summary,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.translationStyle,
  });

  final String text;
  final TranslatableTextKind kind;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final TextStyle? translationStyle;

  @override
  State<BilingualTranslatedText> createState() =>
      _BilingualTranslatedTextState();
}

class _BilingualTranslatedTextState extends State<BilingualTranslatedText> {
  final TranslationFeatureFlags _flags = TranslationFeatureFlags.instance;
  String? _targetLang;
  String? _translation;
  bool _hideTranslation = false;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    _flags.addListener(_onFlags);
    unawaited(_flags.ensureLoaded());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final code = TranslationLanguage.preferredCodeForLocale(
      Localizations.localeOf(context),
    );
    if (code != _targetLang) {
      _targetLang = code;
      _translation = null;
      _hideTranslation = false;
      _requested = false;
      _maybeAuto();
    }
  }

  @override
  void didUpdateWidget(covariant BilingualTranslatedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.kind != widget.kind) {
      _translation = null;
      _hideTranslation = false;
      _requested = false;
      _maybeAuto();
    }
  }

  @override
  void dispose() {
    _flags.removeListener(_onFlags);
    super.dispose();
  }

  void _onFlags() {
    if (!mounted) return;
    setState(() {});
    _maybeAuto();
  }

  bool get _autoEnabled => switch (widget.kind) {
        TranslatableTextKind.title => _flags.autoTitle,
        TranslatableTextKind.tag => _flags.autoTags,
        TranslatableTextKind.summary => _flags.autoSummary,
        TranslatableTextKind.comment => _flags.autoComments,
      };

  void _maybeAuto() {
    unawaited(_maybeAutoAsync());
  }

  Future<void> _maybeAutoAsync() async {
    if (!mounted || _requested || _translation != null) return;
    await _flags.ensureLoaded();
    if (!mounted || _requested || _translation != null) return;
    if (!_flags.bingEnabled || !_autoEnabled) return;
    final target = _targetLang;
    if (target == null) return;
    if (!TranslationLanguage.shouldTranslate(widget.text, target)) return;
    _requested = true;
    await _request(manual: false);
  }

  Future<void> _request({required bool manual}) async {
    final target = _targetLang;
    if (target == null) return;
    try {
      final translated = await UiTextTranslator.instance.translate(
        widget.text,
        targetLang: target,
        manual: manual,
      );
      if (!mounted || translated == null) return;
      setState(() {
        _translation = translated;
        _hideTranslation = false;
      });
    } on Object catch (e) {
      if (!mounted || !manual) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(TranslationException.from(e).message)),
      );
    }
  }

  Future<void> _onLongPress() async {
    if (_translation != null) {
      setState(() => _hideTranslation = !_hideTranslation);
      return;
    }
    _requested = true;
    await _request(manual: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary = widget.translationStyle ??
        widget.style?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontSize: (widget.style?.fontSize ?? 14) * 0.95,
        ) ??
        theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final showTranslation =
        _translation != null && !_hideTranslation && widget.maxLines == null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: _onLongPress,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.text,
            style: widget.style,
            maxLines: widget.maxLines,
            overflow: widget.overflow,
            textAlign: widget.textAlign,
          ),
          if (showTranslation)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.translate_rounded,
                    size: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _translation!,
                      style: secondary,
                      textAlign: widget.textAlign,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 题材标签：保留点按行为，长按触发/切换译文。
class TranslatableTagChip extends StatelessWidget {
  const TranslatableTagChip({
    super.key,
    required this.label,
    required this.onPressed,
    this.tooltip,
  });

  final String label;
  final String? tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: AutoTranslatedText(
        text: label,
        kind: TranslatableTextKind.tag,
      ),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}
