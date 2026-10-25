/// 选区问 AI 对话框 —— 「带着上下文问」的轻量实现。
///
/// 上下文 = 书名 + 章节标题 + 选中文本 + 当前章节正文（超长截断），
/// 不做向量索引；历史问答以文本拼接送入下一次请求（[AiChatClient] 为
/// 单次 system+user 语义，多轮由本对话框自行拼接）。AI 端点与小说翻译
/// 共用「设置 → AI」的多路配置（[AiEndpointRouter] 自动失败切换）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/ai/ai_chat_client.dart';
import '../../../core/ai/vision_translation_client.dart'
    show AiEndpointConfig;
import '../domain/novel_summary_settings.dart';

/// 章节正文注入上限（字符）：控制请求体大小与 token 成本。
const int _kMaxChapterContextChars = 8000;

/// 携带入下一次请求的历史问答轮数上限。
const int _kMaxHistoryTurns = 4;

/// 单条问答消息。
class _AiMessage {
  final bool fromUser;
  final String text;

  const _AiMessage({required this.fromUser, required this.text});
}

/// 选区 / 章节 AI 问答对话框。
class NovelSelectionAiDialog extends StatefulWidget {
  final String bookTitle;
  final String chapterTitle;

  /// 当前章节正文（作为问答上下文注入）。
  final String chapterText;

  /// 触发对话框的选中文本（可为空 = 直接就章节提问）。
  final String selection;

  const NovelSelectionAiDialog({
    super.key,
    required this.bookTitle,
    required this.chapterTitle,
    required this.chapterText,
    this.selection = '',
  });

  @override
  State<NovelSelectionAiDialog> createState() => _NovelSelectionAiDialogState();
}

class _NovelSelectionAiDialogState extends State<NovelSelectionAiDialog> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<_AiMessage> _messages = <_AiMessage>[];
  bool _sending = false;
  bool _noEndpoints = false;

  @override
  void initState() {
    super.initState();
    _resolveEndpoints().then((endpoints) {
      if (mounted && endpoints.isEmpty) {
        setState(() => _noEndpoints = true);
      }
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<List<AiEndpointConfig>> _resolveEndpoints() async {
    try {
      final cfgs =
          await NovelSummarySettings.instance.getTranslationEndpoints();
      return <AiEndpointConfig>[
        for (final c in cfgs)
          if (c.baseUrl.trim().isNotEmpty)
            AiEndpointConfig(
              baseUrl: c.baseUrl,
              apiKey: c.apiKey,
              model: c.model,
            ),
      ];
    } on Object {
      return const <AiEndpointConfig>[];
    }
  }

  String _buildPrompt(String question) {
    final chapter = widget.chapterText.trim();
    final clipped = chapter.length > _kMaxChapterContextChars
        ? '${chapter.substring(0, _kMaxChapterContextChars)}…（后文省略）'
        : chapter;
    final history = _messages.length <= 2
        ? ''
        : <String>[
            for (final m in _messages.sublist(
              _messages.length >= _kMaxHistoryTurns * 2
                  ? _messages.length - _kMaxHistoryTurns * 2
                  : 0,
            ))
              m.fromUser ? 'Q：${m.text}' : 'A：${m.text}',
          ].join('\n');
    return <String>[
      '【书籍】${widget.bookTitle}',
      '【章节】${widget.chapterTitle}',
      if (widget.selection.trim().isNotEmpty)
        '【用户选中的文本】${widget.selection.trim()}',
      '【章节正文】$clipped',
      if (history.isNotEmpty) '【此前问答】\n$history',
      '【问题】$question',
    ].join('\n\n');
  }

  Future<void> _send() async {
    final question = _input.text.trim();
    if (question.isEmpty || _sending) return;
    final endpoints = await _resolveEndpoints();
    if (endpoints.isEmpty) {
      setState(() => _noEndpoints = true);
      return;
    }
    final prompt = _buildPrompt(question);
    setState(() {
      _sending = true;
      _messages.add(_AiMessage(fromUser: true, text: question));
      _input.clear();
    });
    _scrollToEnd();
    try {
      final answer = await AiChatClient().complete(
        endpoints,
        system: '你是阅读助手。用户正在阅读一本小说并就其中的内容提问。'
            '优先依据提供的章节正文与选中文本回答；上下文没有的信息如实说明'
            '是推测或无法确定。使用与提问相同的语言回答，简洁准确。',
        user: prompt,
        temperature: 0.4,
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _messages.add(_AiMessage(fromUser: false, text: answer.trim()));
      });
    } on Object {
      if (!mounted) return;
      setState(() => _sending = false);
    }
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Widget _buildMessages(AppLocalizations l10n, ColorScheme cs) {
    if (_messages.isEmpty && !_noEndpoints) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.selection.trim().isNotEmpty
                ? '“${_ellipsis(widget.selection, 60)}”'
                : l10n.askAiHint,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _messages.length + (_sending ? 1 : 0),
      itemBuilder: (_, i) {
        if (i >= _messages.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: <Widget>[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(
                  l10n.askAiThinking,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          );
        }
        final m = _messages[i];
        final mine = m.fromUser;
        return Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72,
            ),
            decoration: BoxDecoration(
              color: mine
                  ? cs.primary.withValues(alpha: 0.12)
                  : cs.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(12),
                topRight: const Radius.circular(12),
                bottomLeft: Radius.circular(mine ? 12 : 2),
                bottomRight: Radius.circular(mine ? 2 : 12),
              ),
            ),
            child: SelectableText(
              m.text,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(height: 1.45),
            ),
          ),
        );
      },
    );
  }

  static String _ellipsis(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
              child: Row(
                children: <Widget>[
                  Icon(Icons.auto_awesome_rounded,
                      size: 20, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          l10n.askAiTitle,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          l10n.askAiContextTag(
                            _ellipsis(widget.bookTitle, 18),
                            _ellipsis(widget.chapterTitle, 18),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(child: _buildMessages(l10n, cs)),
            if (_noEndpoints)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  l10n.askAiNoEndpoints,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.error),
                ),
              ),
            const Divider(height: 1),
            Padding(
              padding: EdgeInsets.fromLTRB(
                12,
                8,
                _sending ? 12 : 4,
                12,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: !_sending,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: l10n.askAiHint,
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  if (!_sending)
                    IconButton.filledTonal(
                      icon: const Icon(Icons.send_rounded, size: 18),
                      onPressed: _send,
                      tooltip: l10n.askAiSend,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
