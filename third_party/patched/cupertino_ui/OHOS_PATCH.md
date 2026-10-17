# OHOS 适配补丁说明

- 来源：cupertino_ui-1.1.1（pub.dev 原样拷贝）
- 补丁：在每个 `case TargetPlatform.android:` 前插入空 case `case TargetPlatform.ohos:`，使鸿蒙分支沿用 Android（移动端）语义，同时满足枚举穷尽性检查。
- 由 tool/patch_target_platform_ohos.js 机械生成，勿手改；升级版本时重跑脚本。
