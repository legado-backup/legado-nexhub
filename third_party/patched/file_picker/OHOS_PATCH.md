# OHOS 适配补丁说明

- 来源：file_picker 8.0.7 ohos 分支（gitcode CPF-Flutter/fluttertpc_file_picker，path .）
- 补丁：`FilePickerIO.getDirectoryPath` 兼容鸿蒙原生 dir 方法返回的 List（原实现按 String 强转崩溃）。
- 勿手改；上游修复后删除本补丁并改回 git 源。
