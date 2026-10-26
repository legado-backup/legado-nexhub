/// 分格聚焦状态：手动点选与注视停留的统一控制器。
///
/// 不依赖 Flutter widget 层，可在任意环境单测。注视使用 [Timer] 去抖：
/// 停留 [gazeDwell] 后聚焦，目标消失 [gazeRelease] 后释放；任何手动
/// `focus/toggle/unfocus` 都会接管并取消注视计时器。
library;

import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import 'panel_layout.dart';

/// 聚焦模式。
enum PanelFocusMode {
  /// 任何时刻最多一格。
  exclusive,

  /// 可叠加多格。
  multi,
}

/// 分格聚焦控制器。只在 [primaryId] / [focusedIds] 实际变化时通知。
class PanelFocusController extends ChangeNotifier {
  PanelFocusController({
    this.mode = PanelFocusMode.exclusive,
    this.gazeDwell = const Duration(milliseconds: 600),
    this.gazeRelease = const Duration(milliseconds: 1200),
  });

  final PanelFocusMode mode;
  final Duration gazeDwell;
  final Duration gazeRelease;

  final Set<String> _focused = <String>{};
  String? _gazeTarget;
  String? _gazeCommitted;
  Timer? _dwellTimer;
  Timer? _releaseTimer;

  /// 最近聚焦的格；无焦为 null。
  String? get primaryId => _focused.isEmpty ? null : _focused.last;

  Set<String> get focusedIds => Set<String>.unmodifiable(_focused);

  bool get hasFocus => _focused.isNotEmpty;

  bool isFocused(String id) => _focused.contains(id);

  /// 手动聚焦（exclusive 会替换既有焦点，multi 追加）。
  void focus(String id) {
    _takeOverFromGaze();
    if (_addFocus(id)) notifyListeners();
  }

  /// 手动切换：已聚焦则取消，否则聚焦。
  void toggle(String id) {
    _takeOverFromGaze();
    final bool changed =
        _focused.contains(id) ? _removeFocus(id) : _addFocus(id);
    if (changed) notifyListeners();
  }

  /// 取消焦点：[id] 为 null 时清空全部。
  void unfocus([String? id]) {
    _takeOverFromGaze();
    final bool changed =
        id == null ? _clearFocus() : _removeFocus(id);
    if (changed) notifyListeners();
  }

  /// 按布局命中并切换；命中返回 true。未命中但有焦点时清焦并返回 true。
  bool tapAt(PanelLayout layout, Offset localPosition) {
    final String? hit = layout.hitTest(localPosition);
    if (hit != null) {
      toggle(hit);
      return true;
    }
    if (!hasFocus) return false;
    unfocus();
    return true;
  }

  /// 注视目标变化；null 表示离开。
  void updateGaze(String? panelId) {
    _releaseTimer?.cancel();
    _releaseTimer = null;
    if (panelId == null) {
      _dwellTimer?.cancel();
      _dwellTimer = null;
      _gazeTarget = null;
      if (_gazeCommitted != null) {
        _releaseTimer = Timer(gazeRelease, _releaseGaze);
      }
      return;
    }
    if (panelId == _gazeTarget) return;
    _gazeTarget = panelId;
    _dwellTimer?.cancel();
    _dwellTimer = Timer(gazeDwell, () => _commitGaze(panelId));
  }

  /// 立即结束注视（取消去抖并释放由注视建立的焦点）。
  void clearGaze() {
    _dwellTimer?.cancel();
    _releaseTimer?.cancel();
    _dwellTimer = null;
    _releaseTimer = null;
    _gazeTarget = null;
    final String? committed = _gazeCommitted;
    _gazeCommitted = null;
    if (committed != null && _removeFocus(committed)) notifyListeners();
  }

  @override
  void dispose() {
    _dwellTimer?.cancel();
    _releaseTimer?.cancel();
    super.dispose();
  }

  void _takeOverFromGaze() {
    _dwellTimer?.cancel();
    _releaseTimer?.cancel();
    _dwellTimer = null;
    _releaseTimer = null;
    _gazeTarget = null;
    _gazeCommitted = null;
  }

  bool _addFocus(String id) {
    if (_focused.contains(id)) return false;
    if (mode == PanelFocusMode.exclusive) _focused.clear();
    _focused.add(id);
    return true;
  }

  bool _removeFocus(String id) => _focused.remove(id);

  bool _clearFocus() {
    if (_focused.isEmpty) return false;
    _focused.clear();
    return true;
  }

  void _commitGaze(String id) {
    _dwellTimer = null;
    if (_gazeTarget != id) return;
    final String? previous = _gazeCommitted;
    if (previous == id) return;
    bool changed = false;
    if (previous != null) changed = _removeFocus(previous);
    changed = _addFocus(id) || changed;
    if (!changed) return;
    // 仅由注视引起的状态变化才归注视所有；手动已聚焦的格不被注视释放清掉。
    _gazeCommitted = id;
    notifyListeners();
  }

  void _releaseGaze() {
    _releaseTimer = null;
    final String? committed = _gazeCommitted;
    _gazeCommitted = null;
    _gazeTarget = null;
    if (committed != null && _removeFocus(committed)) notifyListeners();
  }
}
