# OHOS 补丁说明：wakelock_plus_ohos

## 为什么有这个本地副本

`media_kit_video` 的鸿蒙分支（`feat-ohos-hdr`）依赖 `wakelock_plus_ohos: ^0.0.3`，
而 pub.dev 上 `wakelock_plus_ohos 0.0.3` 的 SDK 约束是：

```
environment:
  sdk: '>=2.19.6 <3.0.0'
```

本项目使用 Dart 3.13（Flutter 3.47-ohos），`pub get` 会直接拒绝解析。

## 改了什么

`pubspec.yaml` 两处：

1. `sdk` 约束 `>=2.19.6 <3.0.0` → `>=2.19.6 <4.0.0`
2. `plugin.platforms.ohos.pluginClass` `WakelockPlugin` → `WakelockPlusOhosPlugin`，
   避免与 `wakelock_plus`（fluttertpc 适配包，同样导出 `WakelockPlugin`）在生成的
   `GeneratedPluginRegistrant.ets` 里重名冲突（Duplicate identifier）。
   本包对鸿蒙原生侧是 default export，别名无关紧要；运行期媒体内核走的是
   `wakelock_plus` 本体，本包仅满足 `media_kit_video` 的声明依赖。

Dart 侧代码、`ohos/` 原生工程均未改动，来源为 pub.dev 官方归档
`wakelock_plus_ohos-0.0.3.tar.gz`。

## 何时可以删掉

上游把 SDK 约束放宽到 3.x（或本项目迁移到不再依赖该包的版本）后：

1. 删除 `pubspec_overrides.yaml` 里的 `wakelock_plus_ohos: path: ...` 覆盖
2. 删除本目录
3. `flutter pub get`
