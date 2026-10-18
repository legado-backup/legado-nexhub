# 预置鸿蒙播放内核 libmpv.so（构建前一次性准备）
#
# 背景：media_kit_libs_ohos 的 CMake 会在构建期从 GitHub Release 下载
# libmpv_aarch64.zip 并校验 SHA256，然后解压到 <包目录>/ohos/libs/arm64-v8a/。
# 该目录非空时 CMake 会跳过下载，因此可在构建前手工预置，绕开网络问题。
#
# 用法（PowerShell 7）：
#   pwsh -File tool/fetch_ohos_libmpv.ps1
#   pwsh -File tool/fetch_ohos_libmpv.ps1 -Force   # 强制重新下载
#
# 注意：产物位于 pub 缓存里的 media_kit_libs_ohos 包目录，不在本仓库内；
# 清 pub 缓存（或在另一台机器构建）后需重新执行本脚本。

param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$assetName = 'libmpv_aarch64.zip'
$zipSha256 = '140e2c5a6d38572a1f8418cc2463c330077837a38609504c4d532825060e8617'
$soSha256 = '6add9a06c5c9f4993895a9aa7ef6f541c499d3d8461d949ce0ace2377acbf940'
$releaseUrl = "https://github.com/p1nbored/libmpv-ohos-build/releases/download/20261013-hdr/$assetName"
# 国内直连 GitHub 常失败时的镜像前缀（与其它构建脚本保持一致）
$mirrors = @('', 'https://ghfast.top/')

$repoRoot = Split-Path -Parent $PSScriptRoot
$packageConfig = Join-Path $repoRoot '.dart_tool/package_config.json'

if (-not (Test-Path $packageConfig)) {
    throw "未找到 .dart_tool/package_config.json，请先执行 flutter pub get"
}

$config = Get-Content $packageConfig -Raw | ConvertFrom-Json
$entry = $config.packages | Where-Object { $_.name -eq 'media_kit_libs_ohos' } | Select-Object -First 1
if (-not $entry) {
    throw "依赖里没有 media_kit_libs_ohos，请检查 pubspec_overrides.yaml 是否已生效"
}

# rootUri 形如 file:///E:/pub_cache_ohos/git/xxx/libs/ohos/media_kit_libs_ohos 或相对路径
$rootUri = [string]$entry.rootUri
if ($rootUri.StartsWith('file:')) {
    $pkgDir = ([uri]$rootUri).LocalPath
} else {
    $pkgDir = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $packageConfig) $rootUri))
}

$targetDir = Join-Path $pkgDir 'ohos/libs/arm64-v8a'
$targetSo = Join-Path $targetDir 'libmpv.so'

Write-Host "包目录: $pkgDir"
Write-Host "目标路径: $targetSo"

if ((Test-Path $targetSo) -and -not $Force) {
    $existing = (Get-FileHash $targetSo -Algorithm SHA256).Hash.ToLower()
    if ($existing -eq $soSha256) {
        Write-Host "libmpv.so 已就位且校验一致，跳过下载。" -ForegroundColor Green
        return
    }
    Write-Warning "已存在的 libmpv.so 校验不一致（$existing），将重新下载。"
}

$tmpDir = Join-Path $repoRoot '_tmp'
if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir | Out-Null }
$zipPath = Join-Path $tmpDir $assetName

$downloaded = $false
foreach ($prefix in $mirrors) {
    $url = "$prefix$releaseUrl"
    try {
        Write-Host "下载: $url"
        Invoke-WebRequest -Uri $url -OutFile $zipPath -TimeoutSec 300 -UseBasicParsing
        $hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
        if ($hash -eq $zipSha256) {
            Write-Host "SHA256 校验通过。" -ForegroundColor Green
            $downloaded = $true
            break
        }
        Write-Warning "SHA256 不匹配（$hash），尝试下一个源。"
    } catch {
        Write-Warning "下载失败：$($_.Exception.Message)"
    }
}

if (-not $downloaded) {
    throw "全部下载源均失败。请手动下载 $releaseUrl 并解压 libmpv.so 到 $targetDir"
}

if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force }
New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
Expand-Archive -Path $zipPath -DestinationPath $targetDir -Force

if (-not (Test-Path $targetSo)) {
    # 部分包内是 zip 套 zip 或带一层目录，做一次兜底搜索
    $found = Get-ChildItem -Path $targetDir -Recurse -Filter 'libmpv.so' | Select-Object -First 1
    if ($found) {
        Move-Item $found.FullName $targetSo -Force
    } else {
        throw "解压后未找到 libmpv.so，请检查压缩包结构。"
    }
}

$final = (Get-FileHash $targetSo -Algorithm SHA256).Hash.ToLower()
$sizeMb = [math]::Round((Get-Item $targetSo).Length / 1MB, 1)
if ($final -eq $soSha256) {
    Write-Host "完成：libmpv.so（$sizeMb MB）已就位，校验一致。" -ForegroundColor Green
} else {
    Write-Warning "libmpv.so 已就位（$sizeMb MB），但校验值 $final 与预期不符；上游换版时请更新脚本内的常量。"
}
