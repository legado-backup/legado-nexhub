/// 详情页 / 评论等 UI 文本译文缓存（Hive box `text_translations`）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';

class TextTranslationCache {
  static const String boxName = 'text_translations';

  Box<dynamic>? _box;
  bool _tried = false;

  static String keyFor(String target, String source) =>
      '$target|${md5.convert(utf8.encode(source))}';

  Future<Box<dynamic>?> _ensureBox() async {
    if (_box != null) return _box;
    if (_tried) return _box;
    _tried = true;
    try {
      _box = Hive.isBoxOpen(boxName)
          ? Hive.box(boxName)
          : await Hive.openBox(boxName);
    } on Object {
      // Hive 未初始化（测试）时退化为无持久缓存。
    }
    return _box;
  }

  Future<String?> get(String target, String source) async {
    final box = await _ensureBox();
    if (box == null) return null;
    try {
      final raw = box.get(keyFor(target, source));
      if (raw is! String || raw.isEmpty) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final text = decoded['t'] as String?;
      return (text == null || text.isEmpty) ? null : text;
    } on Object {
      return null;
    }
  }

  Future<void> put(String target, String source, String translation) async {
    final box = await _ensureBox();
    if (box == null) return;
    try {
      await box.put(
        keyFor(target, source),
        jsonEncode(<String, dynamic>{
          't': translation,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } on Object {
      // 缓存写失败不影响展示。
    }
  }

  int count() => Hive.isBoxOpen(boxName) ? Hive.box(boxName).length : 0;

  Future<void> clear() async {
    if (!Hive.isBoxOpen(boxName)) return;
    await Hive.box(boxName).clear();
  }
}
