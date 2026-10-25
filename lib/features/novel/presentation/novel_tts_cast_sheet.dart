/// 阅读器「角色与声音」面板（多角色朗读管理入口）。
///
/// 三块内容：
/// 1. **全局声音槽**：在线 HTTP TTS 的旁白/男/女兜底音色（存
///    [NovelHttpTtsConfig]）与系统 TTS 的旁白/男/女声音（存阅读器偏好）；
/// 2. **本书角色卡**：名字/别名/性别/双域音色绑定/启停/删除，可手动添加
///    （[NovelTtsCastStore]，AI 归因发现的新角色也在此出现）；
/// 3. **AI 归因本章**：手动触发 [NovelTtsStoryboardService] 强制刷新当前章
///    归因（无配置/失败有明确提示；成功后新角色自动入列）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/novel/novel_http_tts_config.dart';
import '../../../core/novel/novel_reader_preferences.dart';
import '../../../core/novel/novel_speech_segmenter.dart' show SpeechGender;
import '../../../core/novel/novel_tts_cast_store.dart';
import '../../../core/novel/novel_tts_engine.dart';
import '../../../core/utils/app_log.dart';
import 'package:nexhub/generated/app_localizations.dart';
import '../../novel/domain/novel_tts_storyboard_service.dart';
import 'novel_tts_controller.dart';

/// 打开「角色与声音」面板。
Future<void> showNovelTtsCastSheet({
  required BuildContext context,
  required String novelId,
  required String? chapterId,
  required List<String> paragraphs,
  required NovelReaderPreferences prefs,
  required ValueChanged<NovelReaderPreferences> onPrefsChanged,
  required NovelTtsController tts,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => NovelTtsCastSheet(
      novelId: novelId,
      chapterId: chapterId,
      paragraphs: paragraphs,
      prefs: prefs,
      onPrefsChanged: onPrefsChanged,
      tts: tts,
    ),
  );
}

class NovelTtsCastSheet extends StatefulWidget {
  const NovelTtsCastSheet({
    super.key,
    required this.novelId,
    required this.chapterId,
    required this.paragraphs,
    required this.prefs,
    required this.onPrefsChanged,
    required this.tts,
  });

  final String novelId;
  final String? chapterId;
  final List<String> paragraphs;
  final NovelReaderPreferences prefs;
  final ValueChanged<NovelReaderPreferences> onPrefsChanged;
  final NovelTtsController tts;

  @override
  State<NovelTtsCastSheet> createState() => _NovelTtsCastSheetState();
}

class _NovelTtsCastSheetState extends State<NovelTtsCastSheet> {
  List<NovelCastCharacter> _characters = const <NovelCastCharacter>[];
  NovelHttpTtsConfig _httpTts = const NovelHttpTtsConfig();
  List<NovelTtsVoice> _systemVoices = const <NovelTtsVoice>[];
  bool _aiRunning = false;

  NovelTtsCastStore get _store => NovelTtsCastStore.instance;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final chars = await _store.loadCharacters(widget.novelId);
      final cfg = await NovelHttpTtsConfigStore().load();
      if (!mounted) return;
      setState(() {
        _characters = chars;
        _httpTts = cfg;
      });
    } on Object catch (e) {
      AppLog.instance.w('[角色面板] 加载失败: $e');
    }
    try {
      final voices = await widget.tts.systemVoices();
      if (mounted) setState(() => _systemVoices = voices);
    } on Object {
      // 系统声音枚举失败（平台不支持/引擎未初始化）：槽位仍可手填名字。
    }
  }

  Future<void> _saveHttpTts(NovelHttpTtsConfig next) async {
    setState(() => _httpTts = next);
    await NovelHttpTtsConfigStore().save(next);
  }

  Future<void> _runAiAttribution() async {
    if (_aiRunning) return;
    final l10n = AppLocalizations.of(context);
    final svc = NovelTtsStoryboardService();
    final endpoint = await svc.resolveEndpoint();
    if (endpoint == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.ttsCastAiNoConfig)),
      );
      return;
    }
    setState(() => _aiRunning = true);
    final result = await svc.attributeChapter(
      novelId: widget.novelId,
      chapterId: widget.chapterId ?? '',
      paragraphs: widget.paragraphs,
      forceRefresh: true,
    );
    if (!mounted) return;
    setState(() => _aiRunning = false);
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result == null
          ? l10n.ttsCastAiFailed
          : l10n.ttsCastAiDone(result.entries.length)),
    ));
  }

  Future<void> _editCharacter([NovelCastCharacter? existing]) async {
    final l10n = AppLocalizations.of(context);
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final aliasCtrl =
        TextEditingController(text: existing?.aliases.join('，') ?? '');
    final httpCtrl =
        TextEditingController(text: existing?.httpVoiceId ?? '');
    var gender = existing?.gender ?? SpeechGender.unknown;
    String systemVoice = existing?.systemVoiceName ?? '';

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setDialog) => AlertDialog(
          title: Text(
              existing == null ? l10n.ttsCastAddRole : l10n.ttsCastEditRole),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: nameCtrl,
                  enabled: existing == null,
                  decoration:
                      InputDecoration(labelText: l10n.ttsCastRoleName),
                ),
                TextField(
                  controller: aliasCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.ttsCastAliases,
                    hintText: l10n.ttsCastAliasesHint,
                  ),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: <ButtonSegment<String>>[
                    ButtonSegment<String>(
                        value: SpeechGender.male, label: Text(l10n.ttsCastMale)),
                    ButtonSegment<String>(
                        value: SpeechGender.female,
                        label: Text(l10n.ttsCastFemale)),
                    ButtonSegment<String>(
                        value: SpeechGender.unknown,
                        label: Text(l10n.ttsCastGenderUnknown)),
                  ],
                  selected: <String>{gender},
                  onSelectionChanged: (s) =>
                      setDialog(() => gender = s.first),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: httpCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.ttsCastHttpVoice,
                    hintText: _httpTts.defaultVoice,
                  ),
                ),
                if (_systemVoices.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: systemVoice,
                    elevation: 0,
                    borderRadius: BorderRadius.circular(12),
                    decoration: InputDecoration(
                      labelText: l10n.ttsCastSystemVoice,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    items: <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(
                        value: '',
                        child: Text(l10n.ttsCastEngineDefault),
                      ),
                      for (final v in _systemVoices)
                        DropdownMenuItem<String>(
                          value: v.name,
                          child: Text(
                            v.toString(),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) =>
                        setDialog(() => systemVoice = v ?? ''),
                  ),
                ],
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    final aliases = aliasCtrl.text
        .split(RegExp(r'[，,、\s]+'))
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty)
        .toList();
    await _store.upsert(
      widget.novelId,
      name,
      aliases: aliases,
      gender: gender,
      httpVoiceId: httpCtrl.text.trim(),
      systemVoiceName: systemVoice,
      source: existing?.source ?? NovelCastSource.manual,
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.94,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: <Widget>[
          Text(l10n.ttsCastTitle,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(l10n.ttsCastSubtitle, style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          _buildHttpSlots(context, l10n, theme),
          const SizedBox(height: 12),
          _buildSystemSlots(context, l10n, theme),
          const SizedBox(height: 12),
          _buildCharacters(context, l10n, theme),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _aiRunning ? null : _runAiAttribution,
            icon: _aiRunning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome_rounded),
            label: Text(_aiRunning
                ? l10n.ttsCastAiRunning
                : l10n.ttsCastAiRelabel),
          ),
        ],
      ),
    );
  }

  Widget _buildHttpSlots(BuildContext context, AppLocalizations l10n,
      ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(l10n.ttsCastHttpSlots,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        _voiceField(
          label: l10n.ttsCastNarratorVoice,
          value: _httpTts.narratorVoice,
          hint: _httpTts.defaultVoice,
          onSaved: (v) => _saveHttpTts(_httpTts.copyWith(narratorVoice: v)),
        ),
        _voiceField(
          label: l10n.ttsCastMaleVoice,
          value: _httpTts.maleVoice,
          hint: _httpTts.defaultVoice,
          onSaved: (v) => _saveHttpTts(_httpTts.copyWith(maleVoice: v)),
        ),
        _voiceField(
          label: l10n.ttsCastFemaleVoice,
          value: _httpTts.femaleVoice,
          hint: _httpTts.defaultVoice,
          onSaved: (v) => _saveHttpTts(_httpTts.copyWith(femaleVoice: v)),
        ),
      ],
    );
  }

  Widget _voiceField({
    required String label,
    required String value,
    required String hint,
    required ValueChanged<String> onSaved,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: TextEditingController(text: value),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint.isEmpty ? null : hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: onSaved,
      ),
    );
  }

  Widget _buildSystemSlots(BuildContext context, AppLocalizations l10n,
      ThemeData theme) {
    if (_systemVoices.isEmpty) {
      // 引擎不支持枚举声音（如鸿蒙）：不展示系统槽。
      return const SizedBox.shrink();
    }
    Widget slot(String label, String value, ValueChanged<String> save) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(label),
          subtitle: Text(
              value.isEmpty ? l10n.ttsCastEngineDefault : value,
              overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () async {
            final picked = await showDialog<String>(
              context: context,
              builder: (ctx) => SimpleDialog(
                title: Text(label),
                children: <Widget>[
                  SimpleDialogOption(
                    onPressed: () => Navigator.of(ctx).pop(''),
                    child: Text(l10n.ttsCastEngineDefault),
                  ),
                  for (final v in _systemVoices)
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(ctx).pop(v.name),
                      child: Text(v.toString(),
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
              ),
            );
            if (picked != null) save(picked);
          },
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(l10n.ttsCastSystemSlots,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        slot(l10n.ttsCastNarratorVoice, widget.prefs.ttsSystemNarratorVoice,
            (v) => widget.onPrefsChanged(
                widget.prefs.copyWith(ttsSystemNarratorVoice: v))),
        slot(l10n.ttsCastMaleVoice, widget.prefs.ttsSystemMaleVoice,
            (v) => widget.onPrefsChanged(
                widget.prefs.copyWith(ttsSystemMaleVoice: v))),
        slot(l10n.ttsCastFemaleVoice, widget.prefs.ttsSystemFemaleVoice,
            (v) => widget.onPrefsChanged(
                widget.prefs.copyWith(ttsSystemFemaleVoice: v))),
      ],
    );
  }

  Widget _buildCharacters(BuildContext context, AppLocalizations l10n,
      ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(l10n.ttsCastCharacters,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            IconButton(
              tooltip: l10n.ttsCastAddRole,
              icon: const Icon(Icons.person_add_alt_rounded),
              onPressed: () => _editCharacter(),
            ),
          ],
        ),
        if (_characters.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(l10n.ttsCastEmpty,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          )
        else
          for (final c in _characters)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                c.gender == SpeechGender.female
                    ? Icons.face_3_rounded
                    : Icons.face_rounded,
                color: c.enabled
                    ? null
                    : theme.disabledColor,
              ),
              title: Text(c.name +
                  (c.aliases.isEmpty ? '' : '（${c.aliases.join('、')}）')),
              subtitle: Text(
                <String>[
                  if (c.gender == SpeechGender.male) l10n.ttsCastMale,
                  if (c.gender == SpeechGender.female) l10n.ttsCastFemale,
                  if (c.source == NovelCastSource.ai) 'AI',
                  if (c.httpVoiceId.isNotEmpty) c.httpVoiceId,
                  if (c.systemVoiceName.isNotEmpty) c.systemVoiceName,
                ].join(' · '),
                overflow: TextOverflow.ellipsis,
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'edit') {
                    await _editCharacter(c);
                  } else if (v == 'toggle') {
                    await _store.upsert(widget.novelId, c.name,
                        enabled: !c.enabled);
                    await _reload();
                  } else if (v == 'delete') {
                    await _store.remove(widget.novelId, c.name);
                    await _reload();
                  }
                },
                itemBuilder: (ctx) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                      value: 'edit', child: Text(l10n.ttsCastEditRole)),
                  PopupMenuItem<String>(
                      value: 'toggle',
                      child: Text(c.enabled
                          ? l10n.ttsCastDisable
                          : l10n.ttsCastEnable)),
                  PopupMenuItem<String>(
                      value: 'delete', child: Text(l10n.ttsCastDelete)),
                ],
              ),
              onTap: () => _editCharacter(c),
            ),
      ],
    );
  }
}
