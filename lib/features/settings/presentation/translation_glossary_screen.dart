/// 翻译术语表编辑器（术语表与人名一致性）。
///
/// 两种作用域：
/// - **全局**（设置页入口）：所有作品生效；
/// - **作品级**（阅读器翻译面板入口，传入 [workId]）：展示全局 + 作品
///   合并后的生效表，编辑/新增写入作品级覆盖。
///
/// 翻译后自动提取产生的异译进入「待裁决冲突」区：可采用新译法（写作品级
/// 覆盖）或保留既定译名，裁决前绝不自动覆盖。条目带类型标签，作品级页面
/// 对全局条目以公共图标标注（删除需回全局页）。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/widgets/app_alert_dialog.dart';
import 'package:nexhub/core/widgets/app_animations.dart';
import 'package:share_plus/share_plus.dart';

import '../../novel/domain/novel_summary_settings.dart';

class TranslationGlossaryScreen extends StatefulWidget {
  const TranslationGlossaryScreen({super.key, this.workId, this.manager});

  /// 作品 id；为空时管理全局术语表。
  final String? workId;

  /// 术语管理器（测试注入，默认自建）。
  final GlossaryManager? manager;

  @override
  State<TranslationGlossaryScreen> createState() =>
      _TranslationGlossaryScreenState();
}

class _TranslationGlossaryScreenState extends State<TranslationGlossaryScreen> {
  late final GlossaryManager _manager = widget.manager ?? GlossaryManager();
  List<GlossaryEntry> _entries = const <GlossaryEntry>[];
  List<GlossaryConflict> _conflicts = const <GlossaryConflict>[];
  Set<String> _workTerms = const <String>{};
  bool _loading = true;
  String _lang = '中文';

  String get _scope => widget.workId?.trim().isNotEmpty == true
      ? widget.workId!
      : GlossaryManager.globalWorkId;

  bool get _isGlobal => _scope == GlossaryManager.globalWorkId;

  bool _isWorkEntry(GlossaryEntry entry) =>
      !_isGlobal && _workTerms.contains(entry.term);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _lang =
          await NovelSummarySettings.instance.getTranslationTargetLanguage();
      final workEntries = _isGlobal
          ? const <GlossaryEntry>[]
          : await _manager.entriesFor(_scope, _lang);
      final list = await _manager.effectiveEntries(_scope, _lang);
      final conflicts = _isGlobal
          ? await _manager.openConflicts(lang: _lang)
          : await _manager.openConflicts(workId: _scope, lang: _lang);
      if (!mounted) return;
      setState(() {
        _entries = list;
        _workTerms = <String>{for (final e in workEntries) e.term};
        _conflicts = conflicts;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _upsert(GlossaryEntry entry) async {
    if (_isGlobal) {
      await _manager.saveEntry(GlossaryManager.globalWorkId, _lang, entry);
    } else if (entry.id.isEmpty) {
      // 新增 / 修改全局条目 → 按 term 写入作品覆盖，不重复建同术语。
      await _manager.importMerge(_scope, _lang, <GlossaryEntry>[entry]);
    } else {
      // 修改作品条目按 id 更新，允许改术语原文。
      await _manager.saveEntry(_scope, _lang, entry);
    }
    await _load();
  }

  Future<void> _remove(GlossaryEntry entry) async {
    if (!_isGlobal && !_isWorkEntry(entry)) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.delete),
        content: Text(l10n.glossaryDeleteConfirm(entry.term)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _manager.removeEntry(
      _isGlobal ? GlossaryManager.globalWorkId : _scope,
      _lang,
      entry.id,
    );
    await _load();
  }

  Future<void> _resolveConflict(
    GlossaryConflict conflict,
    GlossaryConflictChoice choice,
  ) async {
    await _manager.resolveConflict(conflict.id, choice);
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).glossaryConflictResolved),
      ),
    );
  }

  Future<void> _showEditor([GlossaryEntry? existing]) async {
    final l10n = AppLocalizations.of(context);
    final termCtrl = TextEditingController(text: existing?.term ?? '');
    final preferredCtrl =
        TextEditingController(text: existing?.preferred ?? '');
    final aliasesCtrl = TextEditingController(
      text: existing?.aliases.join('、') ?? '',
    );
    final noteCtrl = TextEditingController(text: existing?.note ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(existing == null ? l10n.glossaryAdd : l10n.glossaryEdit),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: termCtrl,
                autofocus: existing == null,
                decoration: InputDecoration(
                  labelText: l10n.glossaryTerm,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              TextField(
                controller: preferredCtrl,
                decoration: InputDecoration(
                  labelText: l10n.glossaryPreferred,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              TextField(
                controller: aliasesCtrl,
                decoration: InputDecoration(
                  labelText: l10n.glossaryAliases,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              TextField(
                controller: noteCtrl,
                decoration: InputDecoration(
                  labelText: l10n.glossaryNote,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: termCtrl,
            builder: (context, term, _) =>
                ValueListenableBuilder<TextEditingValue>(
              valueListenable: preferredCtrl,
              builder: (context, pref, _) => FilledButton(
                onPressed:
                    term.text.trim().isNotEmpty && pref.text.trim().isNotEmpty
                        ? () => Navigator.pop(ctx, true)
                        : null,
                child: Text(l10n.save),
              ),
            ),
          ),
        ],
      ),
    );
    // 先取值再释放（退场动画期间控制器仍被输入框引用）。
    final term = termCtrl.text.trim();
    final preferred = preferredCtrl.text.trim();
    final aliasesRaw = aliasesCtrl.text;
    final note = noteCtrl.text.trim();
    termCtrl.dispose();
    preferredCtrl.dispose();
    aliasesCtrl.dispose();
    noteCtrl.dispose();
    if (saved != true) return;
    await _upsert(GlossaryEntry(
      id: existing != null && _isWorkEntry(existing) ? existing.id : '',
      term: term,
      preferred: preferred,
      aliases: <String>[
        for (final a in aliasesRaw.split(RegExp(r'[、,，;；/]'))) a.trim(),
      ].where((a) => a.isNotEmpty).toList(),
      note: note,
      type: existing?.type ?? GlossaryEntry.typeTerm,
      gender: existing?.gender ?? '',
      firstChapter: existing?.firstChapter,
      status: GlossaryEntry.statusOk,
    ));
  }

  Future<void> _export() async {
    final json = GlossaryManager.exportJson(_entries);
    await Share.share(json);
  }

  Future<void> _import() async {
    final l10n = AppLocalizations.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['json', 'txt'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    try {
      final raw = await File(path).readAsString();
      final incoming = GlossaryManager.parseImportJson(raw);
      await _manager.importMerge(_scope, _lang, incoming);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.glossaryImportOk(incoming.length))),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.glossaryImportFail)),
      );
    }
  }

  String _typeLabel(AppLocalizations l10n, String type) => switch (type) {
        'person' => l10n.glossaryTypePerson,
        'place' => l10n.glossaryTypePlace,
        'org' => l10n.glossaryTypeOrg,
        'appellation' => l10n.glossaryTypeAppellation,
        'honorific' => l10n.glossaryTypeHonorific,
        'speech' => l10n.glossaryTypeSpeech,
        'fixed_expression' => l10n.glossaryTypeFixed,
        _ => l10n.glossaryTypeTerm,
      };

  Widget _tag(
    String text,
    ColorScheme scheme, {
    bool error = false,
  }) {
    final background =
        error ? scheme.errorContainer : scheme.secondaryContainer;
    final foreground =
        error ? scheme.onErrorContainer : scheme.onSecondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _entryCard(GlossaryEntry entry, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final ownedByWork = _isWorkEntry(entry);
    final subtitle = <String>[
      if (entry.aliases.isNotEmpty)
        l10n.glossaryAliasesPreview(entry.aliases.join('、')),
      if (entry.note.isNotEmpty) entry.note,
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      child: ListTile(
        title: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '${entry.term} → ${entry.preferred}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (entry.type != GlossaryEntry.typeTerm) ...<Widget>[
              const SizedBox(width: AppTokens.spaceXs),
              _tag(_typeLabel(l10n, entry.type), scheme),
            ],
            if (entry.status == GlossaryEntry.statusConflict) ...<Widget>[
              const SizedBox(width: AppTokens.spaceXs),
              _tag(l10n.glossaryConflictBadge, scheme, error: true),
            ],
          ],
        ),
        subtitle: subtitle.isEmpty
            ? null
            : Text(
                subtitle.join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: _isGlobal || ownedByWork
            ? IconButton(
                icon: const Icon(Icons.delete_rounded),
                onPressed: () => _remove(entry),
              )
            : Tooltip(
                message: l10n.glossaryGlobalEntryHint,
                child: Icon(
                  Icons.public_rounded,
                  size: 18,
                  color: scheme.outline,
                ),
              ),
        onTap: () => _showEditor(entry),
      ),
    );
  }

  Widget _conflictCard(GlossaryConflict conflict, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      color: scheme.errorContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.warning_amber_rounded,
                    size: 18, color: scheme.error),
                const SizedBox(width: AppTokens.spaceXs),
                Expanded(
                  child: Text(
                    conflict.term,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                _tag(l10n.glossaryConflictBadge, scheme, error: true),
              ],
            ),
            const SizedBox(height: AppTokens.spaceXs),
            Text(
              '${l10n.glossaryConflictExisting}：${conflict.existingPreferred}',
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              '${l10n.glossaryConflictProposed}：${conflict.proposed}',
              style: const TextStyle(fontSize: 13),
            ),
            if (conflict.chapterTitle.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppTokens.spaceXs),
                child: Text(
                  l10n.glossaryConflictChapter(conflict.chapterTitle),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            Wrap(
              spacing: AppTokens.spaceSm,
              children: <Widget>[
                FilledButton.tonal(
                  onPressed: () => _resolveConflict(
                      conflict, GlossaryConflictChoice.proposed),
                  child: Text(l10n.glossaryConflictAdopt),
                ),
                TextButton(
                  onPressed: () => _resolveConflict(
                      conflict, GlossaryConflictChoice.existing),
                  child: Text(l10n.glossaryConflictKeep),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final conflictCount = _conflicts.length;
    final headerCount = conflictCount == 0 ? 0 : conflictCount + 1;
    final totalCount = headerCount + _entries.length;
    return AppShrinkTitleScaffold(
      title: Text(_isGlobal ? l10n.glossaryTitle : l10n.glossaryWorkTitle),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTokens.spaceLg, AppTokens.spaceMd, AppTokens.spaceLg, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _isGlobal
                            ? l10n.glossaryScopeGlobal
                            : l10n.glossaryScopeWork,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant),
                      ),
                      Text(
                        l10n.glossaryTargetLang(_lang),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.outline),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: l10n.glossaryImport,
                  icon: const Icon(Icons.upload_file_rounded),
                  onPressed: _import,
                ),
                IconButton(
                  tooltip: l10n.glossaryExport,
                  icon: const Icon(Icons.ios_share_rounded),
                  onPressed: _entries.isEmpty ? null : _export,
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : totalCount == 0
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(AppTokens.spaceXl),
                          child: Text(
                            l10n.glossaryEmpty,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(AppTokens.spaceLg),
                        itemCount: totalCount,
                        itemBuilder: (context, i) {
                          if (conflictCount > 0) {
                            if (i == 0) {
                              return Padding(
                                padding: const EdgeInsets.only(
                                    bottom: AppTokens.spaceSm),
                                child: Text(
                                  l10n.glossaryConflictsTitle(conflictCount),
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(color: scheme.error),
                                ),
                              );
                            }
                            if (i <= conflictCount) {
                              return _conflictCard(
                                  _conflicts[i - 1], l10n);
                            }
                          }
                          return _entryCard(
                            _entries[i - headerCount],
                            l10n,
                          );
                        },
                      ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceLg),
              child: FilledButton.icon(
                onPressed: () => _showEditor(),
                icon: const Icon(Icons.add_rounded),
                label: Text(l10n.glossaryAdd),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
