// 目标平台枚举补丁脚本（Node，一次性维护工具）
//
// 背景：鸿蒙 Flutter fork 在 TargetPlatform 枚举中新增了 `ohos` 值，上游纯 Dart
// 库（material_ui / cupertino_ui 等）里对 `switch (platform)` 的穷尽匹配因此
// 变成非穷尽 → 鸿蒙目标编译报 "not exhaustively matched"。
//
// 做法：在每个 `case TargetPlatform.android:` 前插入空 case
// `case TargetPlatform.ohos:`，使 ohos 落到 Android（移动端）分支。
//
// 用法（升级 material_ui/cupertino_ui 版本后重跑）：
//   1) 确认新版本已下载到 PUBCACHE（flutter pub get 一次）
//   2) node tool/patch_target_platform_ohos.js <源目录名> <目标目录名>
//      例：node tool/patch_target_platform_ohos.js material_ui-1.5.0 third_party/patched/material_ui
"use strict";

const fs = require("fs");

const [, , srcName, dstPath] = process.argv;
if (!srcName || !dstPath) {
  console.error("用法: node tool/patch_target_platform_ohos.js <pub缓存目录名> <目标路径>");
  process.exit(1);
}

const cacheRoot =
  process.env.PUB_CACHE || "E:/pub_cache_ohos";
const candidates = [
  `${cacheRoot}/hosted/pub.flutter-io.cn/${srcName}`,
  `${cacheRoot}/hosted/pub.dev/${srcName}`,
];
const src = candidates.find((p) => fs.existsSync(p));
if (!src) {
  console.error(`未找到源包：${candidates.join(" / ")}`);
  process.exit(1);
}

fs.rmSync(dstPath, { recursive: true, force: true });
fs.mkdirSync(dstPath, { recursive: true });
for (const f of ["lib", "pubspec.yaml", "LICENSE", "README.md", "CHANGELOG.md"]) {
  const p = `${src}/${f}`;
  if (fs.existsSync(p)) fs.cpSync(p, `${dstPath}/${f}`, { recursive: true });
}

let files = 0;
let inserts = 0;
(function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = `${dir}/${e.name}`;
    if (e.isDirectory()) {
      walk(p);
      continue;
    }
    if (!e.name.endsWith(".dart")) continue;
    const before = fs.readFileSync(p, "utf8");
    let n = 0;
    // ① switch 语句：`case TargetPlatform.android:` 前插入空 case。
    let after = before.replace(
      /([ \t]*)case TargetPlatform\.android:/g,
      (_m, indent) => {
        n += 1;
        return `${indent}case TargetPlatform.ohos:\n${indent}case TargetPlatform.android:`;
      },
    );
    // ② switch 表达式模式链内（android 前面已有其它平台模式）：
    //      TargetPlatform.iOS || TargetPlatform.android || ... =>
    after = after.replace(
      /TargetPlatform\.(?!ohos\b)(\w+)(\s*\|\|)(\s*)TargetPlatform\.android(\s*\|\|)/g,
      (_m, first, sep1, sp, sep2) => {
        n += 1;
        return `TargetPlatform.${first}${sep1}${sp}TargetPlatform.ohos || TargetPlatform.android${sep2}`;
      },
    );
    // ③ switch 表达式模式组（行首形态）：
    //      TargetPlatform.android ||
    //      TargetPlatform.fuchsia || ... => x
    after = after.replace(
      /(^|\n)([ \t]*)TargetPlatform\.android\s*\|\|/g,
      (_m, nl, indent) => {
        n += 1;
        return `${nl}${indent}TargetPlatform.ohos || TargetPlatform.android ||`;
      },
    );
    // ③ 模式组紧跟 `{`（单行 switch 表达式）：`{ TargetPlatform.android || ...`
    after = after.replace(
      /\{([ \t]*)TargetPlatform\.android\s*\|\|/g,
      (_m, sp) => {
        n += 1;
        return `{${sp}TargetPlatform.ohos || TargetPlatform.android ||`;
      },
    );
    // ④ 模式组以 android 结尾：`... || TargetPlatform.android =>`
    after = after.replace(
      /TargetPlatform\.android(\s*)=>(\s*)/g,
      (_m, sp1, sp2) => {
        n += 1;
        return `TargetPlatform.ohos || TargetPlatform.android${sp1}=>${sp2}`;
      },
    );
    if (n > 0) {
      fs.writeFileSync(p, after, "utf8");
      files += 1;
      inserts += n;
    }
  }
})(`${dstPath}/lib`);

fs.writeFileSync(
  `${dstPath}/OHOS_PATCH.md`,
  "# OHOS 适配补丁说明\n\n" +
    `- 来源：${srcName}（pub.dev 原样拷贝）\n` +
    "- 补丁：在每个 `case TargetPlatform.android:` 前插入空 case " +
    "`case TargetPlatform.ohos:`，使鸿蒙分支沿用 Android（移动端）语义，" +
    "同时满足枚举穷尽性检查。\n" +
    "- 由 tool/patch_target_platform_ohos.js 机械生成，勿手改；升级版本时重跑脚本。\n",
  "utf8",
);

console.log(`${dstPath}: ${files} 个文件、${inserts} 处插入`);
