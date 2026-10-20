/// 默认下载路径识别：
/// - 空串与旧版硬编码 `D:/Downloads` 都视为「未设置」；
/// - 用户真实选择的路径不被误判。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/download/download_file_system.dart';
import 'package:nexhub/core/download/download_settings.dart';

void main() {
  test('未设置路径识别', () {
    expect(isUnsetDownloadPath(''), isTrue);
    expect(isUnsetDownloadPath(kLegacyDefaultDownloadPath), isTrue);
    expect(isUnsetDownloadPath('C:/Users/someone/Downloads'), isFalse);
    expect(isUnsetDownloadPath('content://tree/primary%3ADownload'), isFalse);
  });

  test('出厂设置不再写死 D 盘路径', () {
    expect(const DownloadSettings.defaults().downloadPath, isEmpty);
    expect(const DownloadSettings().downloadPath, isEmpty);
  });

  test('旧版持久化默认值在加载后仍被识别为未设置', () {
    final DownloadSettings legacy = DownloadSettings.fromJsonString(
      '{"downloadPath":"D:/Downloads"}',
    );
    expect(isUnsetDownloadPath(legacy.downloadPath), isTrue);

    final DownloadSettings saved = DownloadSettings.fromJsonString(
      '{"downloadPath":"C:/Users/someone/Downloads"}',
    );
    expect(isUnsetDownloadPath(saved.downloadPath), isFalse);
  });
}
